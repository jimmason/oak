--[[ Minimal JSON decoder for OAK service responses.
Supports objects, arrays, strings (with basic escapes), numbers, true/false/null. ]]

local OakJson = {}

local function skipWs(s, i)
    local _, j = s:find("^[ \t\r\n]*", i)
    return j + 1
end

local decodeValue

local function decodeString(s, i)
    -- i points at opening quote
    local buf, j = {}, i + 1
    while j <= #s do
        local c = s:sub(j, j)
        if c == '"' then
            return table.concat(buf), j + 1
        elseif c == "\\" then
            local e = s:sub(j + 1, j + 1)
            local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b",
                          f = "\f", n = "\n", r = "\r", t = "\t" }
            if map[e] then
                buf[#buf + 1] = map[e]
                j = j + 2
            elseif e == "u" then
                local hex = s:sub(j + 2, j + 5)
                local cp = tonumber(hex, 16) or 63 -- '?'
                if cp < 0x80 then
                    buf[#buf + 1] = string.char(cp)
                elseif cp < 0x800 then
                    buf[#buf + 1] = string.char(0xC0 + math.floor(cp / 0x40),
                                                0x80 + cp % 0x40)
                else
                    buf[#buf + 1] = string.char(0xE0 + math.floor(cp / 0x1000),
                                                0x80 + math.floor(cp / 0x40) % 0x40,
                                                0x80 + cp % 0x40)
                end
                j = j + 6
            else
                return nil, j, "bad escape"
            end
        else
            buf[#buf + 1] = c
            j = j + 1
        end
    end
    return nil, j, "unterminated string"
end

local function decodeNumber(s, i)
    local numStr = s:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", i)
    local n = tonumber(numStr)
    if n == nil then return nil, i, "bad number" end
    return n, i + #numStr
end

decodeValue = function(s, i)
    i = skipWs(s, i)
    local c = s:sub(i, i)
    if c == '"' then
        return decodeString(s, i)
    elseif c == "{" then
        local obj = {}
        i = skipWs(s, i + 1)
        if s:sub(i, i) == "}" then return obj, i + 1 end
        while true do
            local key, err
            key, i, err = decodeString(s, skipWs(s, i))
            if err then return nil, i, err end
            i = skipWs(s, i)
            if s:sub(i, i) ~= ":" then return nil, i, "expected ':'" end
            local val
            val, i, err = decodeValue(s, i + 1)
            if err then return nil, i, err end
            obj[key] = val
            i = skipWs(s, i)
            local sep = s:sub(i, i)
            if sep == "," then
                i = i + 1
            elseif sep == "}" then
                return obj, i + 1
            else
                return nil, i, "expected ',' or '}'"
            end
        end
    elseif c == "[" then
        local arr = {}
        i = skipWs(s, i + 1)
        if s:sub(i, i) == "]" then return arr, i + 1 end
        while true do
            local val, err
            val, i, err = decodeValue(s, i)
            if err then return nil, i, err end
            arr[#arr + 1] = val
            i = skipWs(s, i)
            local sep = s:sub(i, i)
            if sep == "," then
                i = i + 1
            elseif sep == "]" then
                return arr, i + 1
            else
                return nil, i, "expected ',' or ']'"
            end
        end
    elseif s:sub(i, i + 3) == "true" then
        return true, i + 4
    elseif s:sub(i, i + 4) == "false" then
        return false, i + 5
    elseif s:sub(i, i + 3) == "null" then
        return nil, i + 4
    else
        return decodeNumber(s, i)
    end
end

--- Decode a JSON string. Returns value, or nil + error message.
function OakJson.decode(s)
    if type(s) ~= "string" then return nil, "not a string" end
    local val, i, err = decodeValue(s, 1)
    if err then return nil, err .. " at position " .. tostring(i) end
    return val
end

return OakJson
