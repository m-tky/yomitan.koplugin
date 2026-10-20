-- Executable updates require authenticated HTTPS. Use curl with KOReader's CA
-- bundle rather than LuaSec's default verify=none; never fall back to insecure TLS.
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local Net = {}

function Net.fetch(url, destination, limit, progress, timeout)
    assert(type(url) == "string" and url:match("^https://") and not url:find("[\r\n%z]"), "HTTPS is required")
    local curl = util.which("curl")
    assert(curl, "Secure downloads require curl. Import a local dictionary ZIP, or use Storefront for plugin updates.")
    assert(lfs.attributes("data/ca-bundle.crt", "mode") == "file", "KOReader CA bundle is unavailable")
    local args = {curl, "--disable", "--silent", "--show-error", "--fail", "--location", "--max-redirs", "3",
        "--proto", "=https", "--proto-redir", "=https", "--tlsv1.2", "--cacert", "data/ca-bundle.crt",
        "--connect-timeout", "10", "--max-time", tostring(timeout or 120), "--write-out", "\nYOMITAN_HTTP_STATUS:%{http_code}\n", url}
    local file = assert(io.open(destination, "wb"))
    local pipe = io.popen(util.shell_escape(args) .. " 2>/dev/null", "r")
    if not pipe then file:close(); error("Unable to start secure download") end
    local ok, result = pcall(function()
        local pending, bytes = "", 0
        local function emit(text)
            bytes = bytes + #text
            assert(bytes <= limit, "Download exceeds its size limit")
            assert(file:write(text))
            if progress then progress(bytes) end
        end
        while true do
            local chunk = pipe:read(32768)
            if not chunk then break end
            pending = pending .. chunk
            if #pending > 64 then emit(pending:sub(1, -65)); pending = pending:sub(-64) end
        end
        local tail, status = pending:match("^(.*)\nYOMITAN_HTTP_STATUS:(%d%d%d)\n$")
        assert(status, "Secure download failed or timed out")
        emit(tail)
        return tonumber(status)
    end)
    pipe:close(); file:close()
    assert(ok, result)
    return result
end

return Net
