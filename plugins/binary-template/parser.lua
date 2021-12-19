-- Binary Template plugin for REHex
-- Copyright (C) 2021 Daniel Collins <solemnwarning@solemnwarning.net>
--
-- This program is free software; you can redistribute it and/or modify it
-- under the terms of the GNU General Public License version 2 as published by
-- the Free Software Foundation.
--
-- This program is distributed in the hope that it will be useful, but WITHOUT
-- ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
-- FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
-- more details.
--
-- You should have received a copy of the GNU General Public License along with
-- this program; if not, write to the Free Software Foundation, Inc., 51
-- Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

local M = {}

local lpeg = require 'lpeg'
setmetatable(_ENV, { __index=lpeg })

local function comment(openp,endp)
    openp = P(openp)
    endp = P(endp)
    local upto_endp = (1 - endp) ^ 1
    return openp * upto_endp * endp
end

local function input_pos_to_file_and_line_num(text, pos)
	local filename = "UNKNOWN FILE";
	local line_num = 1;
	
	local i = 1;
	while i <= pos
	do
		local m_filename, m_line_num = text:sub(i, pos):match("#file%s+([^\n]+)%s+(%d+)\n")
		
		if m_filename ~= nil
		then
			filename = m_filename
			line_num = math.floor(m_line_num)
			
			i = text:find("\n", i)
		elseif text:sub(i, i) == "\n"
		then
			line_num = line_num + 1
		end
		
		i = i + 1
	end
	
	return filename, line_num;
end

local function _parser_fallback(text, pos)
	-- Getting here means we're trying to parse something and none of the real captures have
	-- matched, so any actual text is a parse error.
	
	if pos < text:len()
	then
		local pos_filename, pos_line_num = input_pos_to_file_and_line_num(text, pos)
		error("Parse error at " .. pos_filename .. ":" .. pos_line_num)
	end
	
	return nil
end

local function _consume_directive(text, pos)
	-- Directives from the preprocessor begin at column zero, anything else is from the
	-- template source.
	
	if (pos == 2 or text:sub(pos - 2, pos - 2) == "\n") and text:sub(pos - 1, pos - 1) == "#"
	then
		local directive_end = text:find("\n", pos);
		return directive_end + 1;
	end
	
	return nil
end

local function _capture_position(text, pos)
	local filename, line_num = input_pos_to_file_and_line_num(text, pos)
	return pos, filename, line_num
end

local spc = S(" \t\r\n")^0
local digit = R('09')
local number = C( P('-')^-1 * digit^1 * ( P('.') * digit^1 )^-1 ) / tonumber * spc
local letter = R('AZ','az')
local name = C( letter * (digit+letter+"_")^0 ) * spc
local comma  = P(",") * spc

local value_num = Cc("num") * number
local value_ref = Cc("ref") * name
local value = P(_capture_position) * (value_num + value_ref)

local _parser = spc * P{
	"TEMPLATE";
	TEMPLATE = Ct( V("STMT") ^ 0 ),
	
	STMT =
		P(1) * P(_consume_directive) +
		V("BLOCK") +
		V("COMMENT") +
		V("IF") +
		V("WHILE") +
		V("STRUCT_DEFN") +
		V("FUNC_DEFN") +
		V("LOCAL_VAR_DEFN") +
		V("VAR_DEFN") +
		V("EXPR") * P(";") * spc +
		P(1) * P(_parser_fallback),
	
	BLOCK = P("{") * spc * ( V("STMT") ^ 0 ) * spc * P("}"),
	
	COMMENT = spc * comment("//", "\n") * spc
		+ spc * comment("/*", "*/") * spc,
	
	EXPR = V("EXPR_1"),
	
	EXPR_1 =
		Ct( P(_capture_position) * Cc("add")      * V("EXPR_2") * S("+") * spc * V("EXPR_1") ) +
		Ct( P(_capture_position) * Cc("subtract") * V("EXPR_2") * S("-") * spc * V("EXPR_1") ) +
		V("EXPR_2"),
	
	EXPR_2 =
		Ct( P(_capture_position) * Cc("multiply") * V("EXPR_CALL") * S("*") * spc * V("EXPR_2") ) +
		Ct( P(_capture_position) * Cc("divide")   * V("EXPR_CALL") * S("/") * spc * V("EXPR_2") ) +
		V("EXPR_CALL"),
	
	--  {
	--      "call",
	--      "name",
	--      { <arguments> }
	--  }
	EXPR_CALL =
		Ct( P(_capture_position) * Cc("call") * name * Ct( S("(") * (V("EXPR") * (comma * V("EXPR")) ^ 0) ^ -1 * S(")") ) * spc ) +
		V("EXPR_PARENS"),
	
	EXPR_PARENS =
		P("(") * V("EXPR") ^ 1 * P(")") * spc +
		Ct( value ),
	
	VAR_DEFN = Ct( P(_capture_position) * Cc("variable") * name * name * Ct( (P("[") * V("EXPR") * P("]")) ^ -1 ) * P(";") * spc ),
	LOCAL_VAR_DEFN = Ct( P(_capture_position) * Cc("local-variable") * P("local") * spc * name * name * Ct( (P("[") * V("EXPR") * P("]")) ^ -1 ) * spc * Ct( (P("=") * spc * V("EXPR") * spc) ^ -1 ) * P(";") * spc ),
	
	ARG = Ct( name * name ),
	
	--  {
	--      "struct",
	--      "name",
	--      { <arguments> },
	--      { <statements> },
	--  }
	STRUCT_ARG_LIST = Ct( (S("(") * (V("ARG") * (comma * V("ARG")) ^ 0) ^ -1 * S(")")) ^ -1 ),
	STRUCT_DEFN = Ct( P(_capture_position) * Cc("struct") * P("struct") * spc * name * V("STRUCT_ARG_LIST") * spc * P("{") * spc * Ct( V("STMT") ^ 0 ) * P("}") * spc * P(";") ),
	
	--  {
	--      "function",
	--      "return type",
	--      "name",
	--      { <arguments> },
	--      { <statements> },
	--  }
	FUNC_ARG_LIST = Ct( S("(") * (V("ARG") * (comma * V("ARG")) ^ 0) ^ -1 * S(")") ) * spc,
	FUNC_DEFN = Ct( P(_capture_position) * Cc("function") * name * name * V("FUNC_ARG_LIST") * P("{") * spc * Ct( (V("STMT") * spc) ^ 0 ) * P("}") * spc ),
	
	--  {
	--      "if",
	--      { <condition>, { <statements> } },  <-- if
	--      { <condition>, { <statements> } },  <-- else if
	--      { <condition>, { <statements> } },  <-- else if
	--      {              { <statements> } },  <-- else
	--  }
	IF = Ct( P(_capture_position) * Cc("if") *
		Ct( P("if")      * spc * P("(") * V("EXPR") * P(")") * spc * Ct( V("STMT") ) )     * spc *
		Ct( P("else if") * spc * P("(") * V("EXPR") * P(")") * spc * Ct( V("STMT") ) ) ^ 0 * spc *
		Ct( P("else")                                        * spc * Ct( V("STMT") ) ) ^ -1
	),
	
	--  {
	--      "while", <condition>, { <statements> }
	--  }
	WHILE = Ct( P(_capture_position) * Cc("while") *
		P("while") * spc * P("(") * V("EXPR") * P(")") * spc * Ct( V("STMT") ) * spc
	),
}

function parse_text(text)
	return _parser:match(text)
end

M.parse_text = parse_text;

-- local inspect = require 'inspect'
-- print(inspect(M.parser:match(io.input():read("*all"))));

return M