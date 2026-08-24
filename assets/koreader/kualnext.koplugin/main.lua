local Dispatcher = require("dispatcher") -- luacheck:ignore
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local SH_INTEGRATION_CHECK = "test -x /var/local/kmc/bin/sh_integration_launcher"
local LAUNCH_COMMAND = "/bin/sh -c '"
    .. "marker=/var/tmp/kual-next-return-to-koreader; "
    .. ": >\"$marker\" || exit 1; "
    .. "while pidof reader.lua >/dev/null 2>&1 || "
    .. "pidof koreader.sh >/dev/null 2>&1; do sleep 1; done; "
    .. "if ! lipc-set-prop com.lab126.appmgrd start "
    .. "\"app://tech.hackerdude.shell_integration.launcher"
    .. "/mnt/us/documents/KUAL%20Next.sh\"; then "
    .. "rm -f \"$marker\"; exit 1; fi' "
    .. ">>/var/tmp/kual-next.log 2>&1 &"

local KUALNext = WidgetContainer:extend{
    name = "kualnext",
    is_doc_only = false,
}

function KUALNext:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function KUALNext:onDispatcherRegisterActions()
    Dispatcher:registerAction("open_kual_next", {
        category = "none",
        event = "OpenKUALNext",
        title = _("Open KUAL Next"),
        general = true,
    })
end

function KUALNext:addToMainMenu(menu_items)
    menu_items.kual_next = {
        text = _("KUAL Next"),
        sorting_hint = "more_tools",
        callback = function()
            self:onOpenKUALNext()
        end,
    }
end

function KUALNext:_launch()
    local checked, available = pcall(os.execute, SH_INTEGRATION_CHECK)
    if not checked or (available ~= 0 and available ~= true) then
        logger.warn("KUAL Next: SH Integration is not installed", available)
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("KUAL Next requires SH Integration on Kindle."),
        })
        return
    end

    logger.info("KUAL Next: scheduling scriptlet after KOReader exits")
    local executed, status = pcall(os.execute, LAUNCH_COMMAND)
    if not executed or (status ~= 0 and status ~= true) then
        logger.warn("KUAL Next: failed to schedule scriptlet handoff", status)
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("KUAL Next could not be opened. See /var/tmp/kual-next.log for details."),
        })
        return
    end

    UIManager:broadcastEvent(Event:new("Close"))
    UIManager:quit(86)
end

function KUALNext:onOpenKUALNext()
    UIManager:nextTick(function()
        self:_launch()
    end)
end

return KUALNext
