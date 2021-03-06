
--main entry point for all URIs that are not static files.
--provides a hi-level web API and dispatches URIs to individual actions.

local glue = require'glue'
local lfs = require'lfs'
local pp = require'pp'
local cjson = require'cjson'
local lustache = require'lustache'
local ffi = require'ffi'
local ngx = ngx

cjson.encode_sparse_array(false, 0, 0) --encode all sparse arrays

local app = {ngx = false}
setmetatable(app, app)
app._G = app
app.__index = _G
setfenv(1, app)

--logging API ----------------------------------------------------------------

function log(...)
    ngx.log(ngx.DEBUG, ...)
end

--config API -----------------------------------------------------------------

--cached config function. config values may come from `var` statements from
--nginx.conf or from env vars.
--NOTE: env. vars must be declared in nginx.conf to pass through.
local conf = {}
local null = conf
function config(var, default)
	local val = conf[var]
	if val == nil then
		val = os.getenv(var:upper())
		if val == nil then
			val = ngx.var[var]
			if val == nil then
				val = default
			end
		end
		conf[var] = val == nil and null or val
	end
	if val == null then
		return nil
	else
		return val
	end
end

--request API ----------------------------------------------------------------

HEADERS, METHOD, POST, PATH, ARGS, QUERY, GET = nil --for strict mode

local function init_request()
	HEADERS = ngx.req.get_headers()
	METHOD = ngx.req.get_method()
	if METHOD == 'POST' then
		ngx.req.read_body()
		if HEADERS.content_type == 'application/json' then
			POST = cjson.decode(ngx.req.get_body_data())
		else
			POST = ngx.req.get_post_args()
		end
	end
	PATH = ngx.var.uri --TODO: path is unescaped as a whole, not each component
	ARGS = {}
	for s in PATH:gmatch'[^/]+' do
		ARGS[#ARGS+1] = s
	end
	QUERY = ngx.var.query_string
	GET = ngx.req.get_uri_args()
end

--output API -----------------------------------------------------------------

out = ngx.print

function print(...)
	local n = select('#', ...)
	for i=1,n do
		out(tostring((select(i, ...))))
		if i < n then
			out'\t'
		end
	end
	out'\n'
end

app.pp = pp

local mime_types = {
	txt = 'text/plain',
	html = 'text/html',
	json = 'application/json',
}

function setmime(ext)
	ngx.header.content_type = assert(mime_types[ext])
end

redirect = ngx.redirect

--json API -------------------------------------------------------------------

function json(v)
	if type(v) == 'table' then
		return cjson.encode(v)
	elseif type(v) == 'string' then
		return cjson.decode(v)
	else
		error('invalid arg '..type(v))
	end
end

--filesystem API -------------------------------------------------------------

function wwwpath(file) --file -> path (if exists)
	assert(not file:find('..', 1, true))
	return config'www_dir' .. '/' .. file
end

local st = {}
function readfile(name)
	if not st[name] then
		st[name] = assert(glue.readfile(wwwpath(name)))
	end
	return st[name]
end

--template API ---------------------------------------------------------------

function render(name, data, env)
	local function get_partial(_, name)
		return readfile(name:gsub('_(%w+)$', '.%1')) --'name_ext' -> 'name.ext'
	end
	local template = readfile(name)
	env = setmetatable(env or {}, {__index = get_partial})
	return (lustache:render(template, data, env))
end

--socket API -----------------------------------------------------------------

function connect(ip, port)
	local skt = ngx.socket.tcp()
	skt:settimeout(2000)
	local ok, err = skt:connect(ip, port)
	if not ok then return nil, err end
	return skt
end
newthread = ngx.thread.spawn
wait = ngx.thread.wait

--action API -----------------------------------------------------------------

action = {} --{name = handler}

function run()
	--init global and request contexts
	__index = __index._G -- _G is replaced on each request
	__index._G.print = print --replace print for pp
	__index._G.coroutine = require'coroutine' --nginx for windows doesn't include it
	init_request()
	require'actions' --loaded at runtime because it loads this module back.
	--decide on the action: unknown actions go to the default action.
	local act = ARGS[1]
	if not act or not action[act] or act == 'default' then
		act = 'default'
	else
		table.remove(ARGS, 1)
	end
	--find and run the action
	local handler = action[act]
	handler(unpack(ARGS))
end

return app
