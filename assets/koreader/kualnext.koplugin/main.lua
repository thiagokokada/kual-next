local Dispatcher = require("dispatcher") -- luacheck:ignore
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local LAUNCH_COMMAND = "/bin/sh "
    .. "/mnt/us/koreader/plugins/kualnext.koplugin/launcher.sh "
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
    logger.info("KUAL Next: scheduling launcher after KOReader exits")
    local executed, status = pcall(os.execute, LAUNCH_COMMAND)
    if not executed or (status ~= 0 and status ~= true) then
        logger.warn("KUAL Next: failed to start detached launcher", status)
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
