local unified_push_secret = module:get_option_string("unified_push_secret");
local push_registration_ttl = module:get_option_number("unified_push_registration_ttl", 86400);
local push_timeout = module:get_option_number("unified_push_timeout", 120);

local base64 = require "util.encodings".base64;
local datetime = require "util.datetime";
local id = require "util.id";
local jid = require "util.jid";
local jwt = require "util.jwt";
local st = require "util.stanza";
local urlencode = require "util.http".urlencode;

local xmlns_up = "http://gultsch.de/xmpp/drafts/unified-push";

module:depends("http");
module:depends("disco");

module:add_feature(xmlns_up);

local acl = module:get_option_set("unified_push_acl", {
	module:get_host_type() == "local" and module.host or module.host:match("^[^%.]+%.(.+)$")
});

local function is_jid_permitted(user_jid)
	for acl_entry in acl do
		if jid.compare(user_jid, acl_entry) then
			return true;
		end
	end
	return false;
end

local function check_sha256(s)
	if not s then return nil, "no value provided"; end
	local d = base64.decode(s);
	if not d then return nil, "invalid base64"; end
	if #d ~= 32 then return nil, "incorrect decoded length, expected 32"; end
	return s;
end

local push_store = module:open_store();

local backends = {
	jwt = {
		sign = function (data)
			return jwt.sign(unified_push_secret, data);
		end;

		verify = function (token)
			local ok, result = jwt.verify(unified_push_secret, token);

			if not ok then
				return ok, result;
			end
			if result.exp and result.exp < os.time() then
				return nil, "token-expired";
			end
			return ok, result;
		end;
	};

	storage = {
		sign = function (data)
			local reg_id = id.long();
			local ok, err = push_store:set(reg_id, data);
			if not ok then
				return nil, err;
			end
			return reg_id;
		end;
		verify = function (token)
			if token == "_private" then return nil, "invalid-token"; end
			local data = push_store:get(token);
			if not data then
				return nil, "item-not-found";
			elseif data.exp and data.exp < os.time() then
				push_store:set(token, nil);
				return nil, "token-expired";
			end
			return true, data;
		end;
	};
};

if pcall(require, "util.paseto") and require "util.paseto".v3_local then
	local paseto = require "util.paseto".v3_local;
	local state = push_store:get("_private");
	local key = state and state.paseto_v3_local_key;
	if not key then
		key = paseto.new_key();
		push_store:set("_private", { paseto_v3_local_key = key });
	end
	local sign, verify = paseto.init(key);
	backends.paseto = {
		sign = sign;
		verify = function (token)
			local payload, err = verify(token);
			if not payload then
				return nil, err;
			end
			return true, payload;
		end;
	 };
end

local backend = module:get_option_string("unified_push_backend", backends.paseto and "paseto" or "storage");

assert(backend ~= "jwt" or unified_push_secret, "required option missing: unified_push_secret");

local function register_route(params)
	local expiry = os.time() + push_registration_ttl;
	local token, err = backends[backend].sign({
		instance = params.instance;
		application = params.application;
		sub = params.jid;
		exp = expiry;
	});
	if not token then return nil, err; end
	return {
		url = module:http_url("push").."/"..urlencode(token);
		expiry = expiry;
	};
end

-- Handle incoming registration from XMPP client
function handle_register(event)
	module:log("debug", "Push registration request received");
	local origin, stanza = event.origin, event.stanza;
	if not is_jid_permitted(stanza.attr.from) then
		module:log("debug", "Sender <%s> not permitted to register on this UnifiedPush service", stanza.attr.from);
		return origin.send(st.error_reply(stanza, "auth", "forbidden"));
	end
	local instance, instance_err = check_sha256(stanza.tags[1].attr.instance);
	if not instance then
		return origin.send(st.error_reply(stanza, "modify", "bad-request", "instance: "..instance_err));
	end
	local application, application_err = check_sha256(stanza.tags[1].attr.application);
	if not application then
		return origin.send(st.error_reply(stanza, "modify", "bad-request", "application: "..application_err));
	end

	local route, register_err = register_route({
		instance = instance;
		application = application;
		jid = stanza.attr.from;
	});

	if not route then
		module:log("warn", "Failed to create registration using %s backend: %s", backend, register_err);
		return origin.send(st.error_reply(stanza, "wait", "internal-server-error"));
	end

	module:log("debug", "New push registration successful");
	return origin.send(st.reply(stanza):tag("registered", {
		expiration = datetime.datetime(route.expiry);
		endpoint = route.url;
		xmlns = xmlns_up;
	}));
end

module:hook("iq-set/host/"..xmlns_up..":register", handle_register);

-- Decode an endpoint token. For other modules (application servers on this
-- host), e.g. via module:depends("unified_push").verify_token(token).
-- Returns true and { sub, instance, application, exp }, or nil and an error.
function verify_token(token)
	return backends[backend].verify(token);
end

-- Deliver a push to the registration behind token. Returns an HTTP status
-- code, or a promise of one: 201 delivered, 404 unknown/rejected,
-- 400/413 bad payload, 503 recipient unavailable, 500 other errors.
function push(token, payload, push_id)
	local ok, data = backends[backend].verify(token);
	if not ok then
		module:log("debug", "Received push to unacceptable token (%s)", data);
		return 404;
	end
	if not payload or payload == "" then
		module:log("warn", "Missing or empty push payload");
		return 400;
	elseif #payload > 4096 then
		module:log("warn", "Push payload too large");
		return 413;
	end
	push_id = push_id or id.short();
	module:log("debug", "Push notification received [%s], relaying to device...", push_id);
	local push_iq = st.iq({ type = "set", to = data.sub, from = module.host, id = push_id })
		:text_tag("push", base64.encode(payload), { instance = data.instance, application = data.application, xmlns = xmlns_up });
	local function failed(e_type, e_cond, e_text)
		if e_cond == "item-not-found" or e_cond == "feature-not-implemented" then
			module:log("debug", "Push rejected [%s]", push_id);
			return 404;
		elseif e_cond == "service-unavailable" or e_cond == "recipient-unavailable" then
			module:log("debug", "Recipient temporarily unavailable [%s]", push_id);
			return 503;
		end
		module:log("warn", "Unexpected push error response: %s/%s/%s", e_type, e_cond, e_text);
		return 500;
	end
	return module:send_iq(push_iq, nil, push_timeout):next(function (event)
		-- send_iq resolves, not rejects, with an error the server itself
		-- returns through the origin, e.g. service-unavailable when the
		-- recipient's full JID is offline.
		if event.stanza.attr.type == "error" then
			return failed(event.stanza:get_error());
		end
		module:log("debug", "Push notification delivered [%s]", push_id);
		return 201;
	end, function (err)
		-- A util.error: from the recipient's error reply, or a timeout.
		return failed(err.type, err.condition, err.text);
	end);
end

-- Handle incoming POST
function handle_push(event, subpath)
	module:log("debug", "Incoming push received!");
	return push(subpath, event.request.body, event.request.id);
end

module:provides("http", {
	name = "push";
	cors = {
		enabled = true;
		headers = {
			["content-encoding"] = true;
			ttl = true;
		};
	};
	route = {
		["GET /*"] = function (event)
			event.response.headers.content_type = "application/json";
			return [[{"unifiedpush":{"version":1}}]];
		end;
		["POST /*"] = handle_push;
	};
});
