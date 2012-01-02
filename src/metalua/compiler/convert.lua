--*-lua-*-----------------------------------------------------------------------
-- This module is written in a more hackish way than necessary, just
-- because I can.  Its core feature is to dynamically generate a
-- function that converts from a source format to a destination
-- format; these formats are the various ways to represent a piece of
-- program, from the source file to the executable function. Legal
-- formats are:
--
-- * luafile:    the name of a file containing sources.
-- * luastring:  these sources as a single string.
-- * lexstream:  a stream of lexemes.
-- * ast:        an abstract syntax tree.
-- * proto:      a (Yueliang) struture containing a high level 
--               representation of bytecode. Largely based on the 
--               Proto structure in Lua's VM.
-- * luacstring: a string dump of the function, as taken by 
--               loadstring() and produced by string.dump().
-- * function:   an executable lua function in RAM.
--
--------------------------------------------------------------------------------

require 'metalua.bytecode'
require 'metalua.mlp'

mlc = { }
setmetatable(mlc, mlc)
mlc.metabugs = false

--------------------------------------------------------------------------------
-- Order of the transformations. if 'a' is on the left of 'b', then a 'a' can
-- be transformed into a 'b' (but not the other way around).
-- mlc.sequence goes for numbers to format names, mlc.order goes from format
-- names to numbers.
--------------------------------------------------------------------------------
mlc.sequence = {
   'luafile',  'luastring', 'lexstream', 'ast', 'proto', 
   'luacstring', 'function' }
mlc.order = table.transpose(mlc.sequence)

-- Check whether a structure of nested tables is a valid AST.
-- Currently thows an error if it isn't.
-- TODO: return boolean + msg instead of throwing an error when AST is invalid.
-- TODO: build a detailed error location, with the lineinfo of every nested node.
local function check_ast(kind, ast)
    if not ast then return check_ast('block', kind) end
    assert(type(ast)=='table', "wrong AST type")
    local function error2ast(error_node, ...)
        if error_node.tag=='Error' then
            error(error_node[1])
        else
            local li
            for _, n in ipairs{ error_node, ... } do
                li = n.lineinfo
                if li then break end
            end
            local pos = li 
                and string.format("line %d, char #%d, offset %d",
                                  li[1], li[2], li[3])
                or "unknown source position"     
            local msg = "Invalid node tag "..tostring(error_node.tag).." at "..pos
            print (msg)
            table.print(ast, 'nohash')
            error (msg)
        end
    end
    local cfg = { malformed=error2ast; unknown=error2ast }
    local f = require 'metalua.treequery.walk' [kind]
    --print ("Checking AST "..table.tostring(ast, 'nohash'):sub(1, 130))
    f(cfg, ast)
    --print ("Checked AST: success")
end

mlc.check_ast = check_ast

function mlc.luafile_to_luastring(x, name)
    name = name or '@'..x
    local f, msg = io.open (x, 'rb')
    if not f then return f, msg end
    local r = f :read '*a'
    f :close()
    return r, name
end

function mlc.luastring_to_lexstream(src, name)
    local r = mlp.lexer :newstream (src, name)
    return r, name
end

function mlc.lexstream_to_ast(lx, name)
    if PRINT_PARSED_STAT then
        print("About to parse a lexstream, starting with "..tostring(lx:peek()))
    end
    local r = mlp.chunk(lx)    
    r.source = name
    return r, name
end

function mlc.ast_to_proto(ast, name)
    name = name or ast.source
    return bytecode.metalua_compile(ast, name), name
end

function mlc.proto_to_luacstring(proto, name)
    return bytecode.dump_string(proto), name
end

function mlc.luacstring_to_function(bc, name)
    return string.undump(bc, name)
end

-- Create all sensible combinations
for i=1,#mlc.sequence do
    for j=i+2, #mlc.sequence do
        local dst_name = mlc.sequence[i].."_to_"..mlc.sequence[j]
        local functions = { }
        --local n = { }
        for k=i, j-1 do
            local name =  mlc.sequence[k].."_to_"..mlc.sequence[k+1]
            local f = assert(mlc[name])
            table.insert (functions, f)
            --table.insert(n, name)
        end
        mlc[dst_name] = function(a, b)
            for _, f in ipairs(functions) do
                a, b = f(a, b)
            end
            return a, b
        end
        --printf("Created mlc.%s out of %s", dst_name, table.concat(n, ', '))
    end
end


--------------------------------------------------------------------------------
-- This case isn't handled by the __index method, as it goes "in the wrong direction"
--------------------------------------------------------------------------------
mlc.function_to_luacstring = string.dump

--------------------------------------------------------------------------------
-- These are drop-in replacement for loadfile() and loadstring(). The
-- C functions will call them instead of the original versions if
-- they're referenced in the registry.
--------------------------------------------------------------------------------

lua_loadstring = loadstring
local lua_loadstring = loadstring
lua_loadfile = loadfile
local lua_loadfile = loadfile

function loadstring(str, name)
   if type(str) ~= 'string' then error 'string expected' end
   if str:match '^\027LuaQ' then return lua_loadstring(str) end
   local n = str:match '^#![^\n]*\n()'
   if n then str=str:sub(n, -1) end
   -- FIXME: handle erroneous returns (return nil + error msg)
   local success, f = pcall (mlc.luastring_to_function, str, name)
   if success then return f else return nil, f end
end

function loadfile(filename)
   local f, err_msg = io.open(filename, 'rb')
   if not f then return nil, err_msg end
   local success, src = pcall( f.read, f, '*a')
   pcall(f.close, f)
   if success then return loadstring (src, '@'..filename)
   else return nil, src end
end

function load(f, name)
   while true do
      local x = f()
      if not x then break end
      assert(type(x)=='string', "function passed to load() must return strings")
      table.insert(acc, x)
   end
   return loadstring(table.concat(x))
end

function dostring(src)
   local f, msg = loadstring(src)
   if not f then error(msg) end
   return f()
end

function dofile(name)
   local f, msg = loadfile(name)
   if not f then error(msg) end
   return f()
end