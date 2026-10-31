-- mod_pubsub_unified_push: a UnifiedPush application server for pubsub.
--
-- Load on the user host, next to mod_unified_push. Apps register an endpoint
-- (issued by mod_unified_push to their distributor) and a list of topics,
-- which are nodes on a pubsub service. Items published to those nodes are
-- delivered to the endpoint in order, at least once, while they're retained:
-- a cursor per (registration, topic) only advances when the distributor
-- acknowledges a push, and catch-up runs on reconnect and on a timer.
-- Design: docs/design.md

local json = require "prosody.util.json";
local jid_util = require "prosody.util.jid";
local urldecode = require "prosody.util.http".urldecode;
local modulemanager = require "prosody.core.modulemanager";

local pubsub_host = module:get_option_string("pubsub_unified_push_service", "notify."..module.host);
local node_defs = module:get_option("pubsub_unified_push_nodes", {});
local retry_interval = module:get_option_period("pubsub_unified_push_retry_interval", 300);
local max_backoff = module:get_option_period("pubsub_unified_push_max_backoff", 3600);
local expired_grace = module:get_option_period("pubsub_unified_push_expired_grace", 7 * 86400);
local reconnect_delay = module:get_option_period("pubsub_unified_push_reconnect_delay", 2);

local max_payload = 4096; -- mod_unified_push rejects larger bodies

local up = module:depends("unified_push");
assert(up.verify_token and up.push, "mod_unified_push lacks verify_token/push (needs the patched module)");

local store = module:open_store();

-- key ("bare application instance") -> registration
--   persisted: bare, application, instance, token, sub, exp, topics, cursor, first, updated
--   runtime:   busy, again, failures, next_attempt
local regs = {};

local function reg_key(bare, application, instance)
	return bare.." "..application.." "..instance;
end

local persisted_fields = {
	"bare", "application", "instance", "token", "sub", "exp", "topics", "cursor", "first", "updated",
};

local function save_user(bare)
	local data = {};
	for key, reg in pairs(regs) do
		if reg.bare == bare then
			local rec = {};
			for _, field in ipairs(persisted_fields) do rec[field] = reg[field]; end
			data[key] = rec;
		end
	end
	local ok, err = store:set(jid_util.node(bare), next(data) and data or nil);
	if not ok and err then
		module:log("error", "Failed to save registrations for %s: %s", bare, err);
	end
end

local function load_all()
	if not store.users then
		module:log("warn", "Storage can't list users; registrations load as apps re-register");
		return;
	end
	local n = 0;
	for username in store:users() do
		for key, rec in pairs(store:get(username) or {}) do
			regs[key] = rec;
			n = n + 1;
		end
	end
	module:log("debug", "Loaded %d registrations", n);
end

-- The pubsub service lives on another host (a component), which may load
-- before or after this module: attach() on server-started, and lazily
-- wherever the service is needed. It returns the service, or nil.
local service;
local attach;

local function get_service()
	local mod = modulemanager.get_module(pubsub_host, "pubsub");
	return mod and mod.service;
end

-- Make the configured nodes exist with the configured ACLs. Affiliations not
-- in the config are removed, so the config is the source of truth.
local function ensure_nodes(svc)
	for node, def in pairs(node_defs) do
		local config = {
			access_model = "whitelist";
			publish_model = "publishers";
			persist_items = true;
			max_items = def.max_items or 100;
			title = def.title;
		};
		local ok, err = svc:create(node, true, config);
		if not ok and err == "conflict" then
			local _, current = svc:get_node_config(node, true);
			local merged = {};
			for k, v in pairs(current or {}) do merged[k] = v; end
			for k, v in pairs(config) do merged[k] = v; end
			ok, err = svc:set_node_config(node, true, merged);
		end
		if not ok then
			module:log("error", "Can't create or configure node %q on %s: %s", node, pubsub_host, err);
		else
			local want = {};
			for _, j in ipairs(def.publishers or {}) do want[jid_util.bare(j)] = "publisher"; end
			for _, j in ipairs(def.members or {}) do want[jid_util.bare(j)] = want[jid_util.bare(j)] or "member"; end
			local node_obj = svc.nodes[node];
			for j, aff in pairs(node_obj.affiliations) do
				if not want[j] and (aff == "publisher" or aff == "member") then
					svc:set_affiliation(node, true, j, "none");
				end
			end
			for j, aff in pairs(want) do
				if node_obj.affiliations[j] ~= aff then
					svc:set_affiliation(node, true, j, aff);
				end
			end
		end
	end
end

-- Items newer than cursor, oldest first. Cursor "" means everything retained
-- is due; first is then the first item published since (seen on the publish
-- event), which must still be retained. Second return: true if items were
-- missed, i.e. the cursor or first is no longer retained.
local function items_after(svc, node, cursor, first)
	local ok, items = svc:get_items(node, true);
	if not ok then return nil, items; end
	local out, found = {}, cursor == "" and first == nil;
	for _, id in ipairs(items) do -- newest first
		if id == cursor then found = true; break; end
		if id == first then found = true; end
		table.insert(out, 1, { id = id, item = items[id] });
	end
	return out, not found;
end

local function encode_message(topic, id, item)
	local data = json.decode(item:get_child_text("json", "urn:xmpp:json:0") or "");
	if type(data) ~= "table" then
		-- Not one of ours; still say something rather than drop it.
		data = { body = item.tags[1] and item.tags[1]:get_text() or nil };
	end
	local msg = {
		topic = topic; id = id;
		title = type(data.title) == "string" and data.title or topic;
		body = type(data.body) == "string" and data.body or nil;
		url = type(data.url) == "string" and data.url or nil;
		priority = type(data.priority) == "string" and data.priority or nil;
		group = type(data.group) == "string" and data.group or nil;
	};
	local encoded = json.encode(msg);
	while #encoded > max_payload and msg.body and #msg.body > 0 do
		local cut = msg.body:sub(1, math.max(0, #msg.body - (#encoded - max_payload) - 3));
		cut = cut:gsub("[\192-\255][\128-\191]*$", ""); -- don't split a UTF-8 sequence
		msg.body = cut.."…";
		encoded = json.encode(msg);
		if cut == "" then msg.body = nil; encoded = json.encode(msg); end
	end
	return encoded;
end

local run;

local function failed(reg, why)
	reg.busy, reg.again = false, false;
	reg.failures = (reg.failures or 0) + 1;
	local delay = math.min(retry_interval * 2 ^ (reg.failures - 1), max_backoff);
	reg.next_attempt = os.time() + delay;
	module:log("debug", "Push to %s failed (%s), retry in %ds", reg.sub, tostring(why), delay);
end

-- Deliver everything pending for one registration, one push at a time.
function run(reg)
	if reg.busy then reg.again = true; return; end
	if not attach() or not reg.token then return; end
	reg.busy = true;
	reg.first = reg.first or {};

	local queue = {};
	for _, topic in ipairs(reg.topics) do
		local list, gap = items_after(service, topic, reg.cursor[topic] or "", reg.first[topic]);
		if list then
			if gap then queue[#queue+1] = { topic = topic, gap = true }; end
			for _, it in ipairs(list) do
				queue[#queue+1] = { topic = topic, id = it.id, item = it.item };
			end
		else
			module:log("warn", "Can't read node %q: %s", topic, gap);
		end
	end

	local i = 0;
	local function step()
		i = i + 1;
		local q = queue[i];
		if not q then
			reg.busy, reg.failures, reg.next_attempt = false, 0, nil;
			if reg.again then reg.again = false; return run(reg); end
			return;
		end
		local payload = q.gap and json.encode({ topic = q.topic, gap = true })
			or encode_message(q.topic, q.id, q.item);
		local function done(status)
			if status ~= 201 then return failed(reg, status); end
			if q.gap then
				-- Everything still retained is due; remember the oldest so a
				-- further loss is noticed too.
				local nxt = queue[i+1];
				reg.cursor[q.topic] = "";
				reg.first[q.topic] = nxt and nxt.topic == q.topic and nxt.id or nil;
			else
				reg.cursor[q.topic], reg.first[q.topic] = q.id, nil;
			end
			save_user(reg.bare);
			return step();
		end
		local result = up.push(reg.token, payload);
		if type(result) == "table" and result.next then
			result:next(done, function (err) failed(reg, err); end);
		else
			done(result);
		end
	end
	step();
end

local function is_pending(reg)
	for _, topic in ipairs(reg.topics) do
		local ok, last = service:get_last_item(topic, true);
		if ok and last and last ~= reg.cursor[topic] then return true; end
	end
	return false;
end

local function run_for(bare, delay)
	module:add_timer(delay or 0, function ()
		for _, reg in pairs(regs) do
			if reg.bare == bare then run(reg); end
		end
	end);
end

local function on_published(event)
	for _, reg in pairs(regs) do
		for _, topic in ipairs(reg.topics) do
			if topic == event.node then
				reg.first = reg.first or {};
				if (reg.cursor[topic] or "") == "" and reg.first[topic] == nil then
					reg.first[topic] = event.id;
					save_user(reg.bare);
				end
				run(reg);
				break;
			end
		end
	end
end

function attach()
	local svc = get_service();
	if svc and svc ~= service then
		if service then service.events.remove_handler("item-published", on_published); end
		service = svc;
		ensure_nodes(svc);
		svc.events.add_handler("item-published", on_published);
		module:log("debug", "Attached to pubsub on %s", pubsub_host);
	end
	return service;
end

module:hook_global("server-started", function () attach(); end);
module:hook_global("host-activated", function (host)
	if host == pubsub_host then attach(); end
end);

function module.unload()
	if service then service.events.remove_handler("item-published", on_published); end
end

-- Catch up as soon as the phone reconnects. Conversations usually resumes a
-- hibernated session (XEP-0198) rather than binding a new one, so hook both.
module:hook("resource-bind", function (event)
	run_for(jid_util.bare(event.session.full_jid), reconnect_delay);
end);
module:hook("smacks-hibernation-end", function (event)
	run_for(jid_util.bare(event.origin.full_jid), reconnect_delay);
end);

-- Retry anything pending; drop registrations long expired without renewal.
module:add_timer(retry_interval, function ()
	local now = os.time();
	local changed = {};
	for key, reg in pairs(regs) do
		if reg.exp and reg.exp + expired_grace < now then
			module:log("debug", "Dropping expired registration of %s", reg.bare);
			regs[key] = nil;
			changed[reg.bare] = true;
		elseif attach() and not reg.busy and (reg.next_attempt or 0) <= now and is_pending(reg) then
			run(reg);
		end
	end
	for bare in pairs(changed) do save_user(bare); end
	return retry_interval;
end);

-- HTTP registration API

local function token_from(endpoint)
	local token = type(endpoint) == "string" and endpoint:match("/push/([^/?#]+)$");
	return token and urldecode(token);
end

local function parse_request(event)
	local body = json.decode(event.request.body or "");
	if type(body) ~= "table" then return nil, 400; end
	local token = token_from(body.endpoint);
	if not token then return nil, 400; end
	local ok, data = up.verify_token(token);
	if not ok then
		module:log("debug", "Registration with unacceptable endpoint: %s", data);
		return nil, 403;
	end
	local bare = jid_util.bare(data.sub);
	if jid_util.host(bare) ~= module.host then return nil, 403; end
	return body, nil, token, data, bare;
end

local function respond_json(event, status, data)
	event.response.status_code = status;
	event.response.headers.content_type = "application/json";
	return json.encode(data);
end

local function handle_register(event)
	local body, err, token, data, bare = parse_request(event);
	if not body then return err; end
	if not attach() then return 503; end

	local key = reg_key(bare, data.application, data.instance);
	local reg = regs[key] or {
		bare = bare; application = data.application; instance = data.instance;
		topics = {}; cursor = {}; first = {};
	};
	reg.token, reg.sub, reg.exp, reg.updated = token, data.sub, data.exp, os.time();

	local result, topics, cursor = {}, {}, {};
	for _, topic in ipairs(type(body.topics) == "table" and body.topics or {}) do
		if type(topic) == "string" and result[topic] == nil then
			if not service.nodes[topic] then
				result[topic] = "item-not-found";
			elseif not service:may(topic, bare, "get_items") then
				result[topic] = "forbidden";
			else
				result[topic] = "ok";
				topics[#topics+1] = topic;
				if reg.cursor[topic] ~= nil then
					cursor[topic] = reg.cursor[topic];
				else
					-- New topic: start from now, don't replay history.
					local _, last = service:get_last_item(topic, true);
					cursor[topic] = last or "";
				end
			end
		end
	end
	local first = {};
	for _, topic in ipairs(topics) do first[topic] = reg.first and reg.first[topic]; end
	reg.topics, reg.cursor, reg.first = topics, cursor, first;
	reg.failures, reg.next_attempt = 0, nil;
	regs[key] = reg;
	save_user(bare);
	module:log("debug", "Registration for %s: %d topics", data.sub, #topics);
	module:add_timer(0, function () run(reg); end);
	return respond_json(event, 200, { topics = result });
end

local function handle_unregister(event)
	local body, err, _, data, bare = parse_request(event);
	if not body then return err; end
	local key = reg_key(bare, data.application, data.instance);
	if not regs[key] then return 404; end
	regs[key] = nil;
	save_user(bare);
	return 204;
end

module:provides("http", {
	name = "pubsub_push";
	route = {
		["POST /register"] = handle_register;
		["DELETE /register"] = handle_unregister;
	};
});

load_all();
attach();
