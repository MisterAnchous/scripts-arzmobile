script_name('Skip Notify Plus')
script_author('Charlie_Deep t.me/rakbotik')
script_version('2.00')

local encoding = require 'encoding'
local sampev = require 'samp.events'
local imgui = require 'mimgui'
local ffi = require 'ffi'
encoding.default = 'CP1251'
u8 = encoding.UTF8
local CONFIG_DIR_PATH = getWorkingDirectory() .. '/config/SkipNotify'
local CONFIG_PATH = CONFIG_DIR_PATH .. '/skip_notify_plus.ini'
local PACKET_ID = 220
local PACKET_IN = 84
local PACKET_OUT = 63
local SKIP_CEF_IFACE = 87
local SKIP_CEF_SUB = 0
local HIDE_DOWN_IFACE = 6
local HIDE_DOWN_SUB = 0
local HIDE_DOWN_MAX_CLOSES = 60
local config = {
    skip_cef_notify = false,
    hide_down_notify = false,
    pos_x = -1,
    pos_y = -1,
    win_width = 0,
    win_height = 0,
}
local menu_visible = false
local window_open = imgui.new.bool(true)
local last_window_save_time = 0.0
local is_skip_cef_closing = false
local is_hide_down_blocking = false
local is_hide_down_flooding = false
local window_pos_set = false
local palette = {
    window_bg = imgui.ImVec4(0.96, 0.97, 0.99, 0.98),
    title_bg = imgui.ImVec4(0.93, 0.95, 0.98, 1.00),
    child_bg = imgui.ImVec4(0.99, 0.99, 1.00, 1.00),
    border = imgui.ImVec4(0.83, 0.86, 0.91, 1.00),
    text = imgui.ImVec4(0.16, 0.18, 0.22, 1.00),
    text_dim = imgui.ImVec4(0.48, 0.53, 0.61, 1.00),
    success = imgui.ImVec4(0.17, 0.66, 0.33, 1.00),
    switch_on = imgui.ImVec4(0.22, 0.76, 0.35, 1.00),
    switch_off = imgui.ImVec4(0.76, 0.79, 0.84, 1.00),
    switch_knob = imgui.ImVec4(0.98, 0.99, 1.00, 1.00),
}
local function ensure_config_dir()
    if not doesDirectoryExist(CONFIG_DIR_PATH) then
        createDirectory(CONFIG_DIR_PATH)
    end
end
local function bool_to_str(v)
    return v and 'true' or 'false'
end
local function str_to_bool(s)
    return s == 'true'
end
local function save_config()
    ensure_config_dir()
    local f = io.open(CONFIG_PATH, 'w')
    if not f then return end
    f:write('[main]\n')
    f:write('skip_cef_notify=' .. bool_to_str(config.skip_cef_notify) .. '\n')
    f:write('hide_down_notify=' .. bool_to_str(config.hide_down_notify) .. '\n')
    f:write('[window]\n')
    f:write('pos_x=' .. tostring(config.pos_x) .. '\n')
    f:write('pos_y=' .. tostring(config.pos_y) .. '\n')
    f:write('win_width=' .. tostring(config.win_width) .. '\n')
    f:write('win_height=' .. tostring(config.win_height) .. '\n')
    f:close()
end
local function load_config()
    ensure_config_dir()
    local f = io.open(CONFIG_PATH, 'r')
    if not f then
        save_config()
        return
    end
    local section = ''
    for line in f:lines() do
        line = line:match('^%s*(.-)%s*$')
        local sec = line:match('^%[(.+)%]$')
        if sec then
            section = sec
        else
            local key, val = line:match('^([%w_]+)=(.*)$')
            if key and val then
                if section == 'main' then
                    if key == 'skip_cef_notify' then config.skip_cef_notify = str_to_bool(val) end
                    if key == 'hide_down_notify' then config.hide_down_notify = str_to_bool(val) end
                elseif section == 'window' then
                    if key == 'pos_x' then config.pos_x = tonumber(val) or -1 end
                    if key == 'pos_y' then config.pos_y = tonumber(val) or -1 end
                    if key == 'win_width' then config.win_width = tonumber(val) or 0 end
                    if key == 'win_height' then config.win_height = tonumber(val) or 0 end
                end
            end
        end
    end
    f:close()
end
local function to_u32(color)
    return imgui.ColorConvertFloat4ToU32(color)
end
local function clamp(value, min_value, max_value)
    if value < min_value then return min_value end
    if value > max_value then return max_value end
    return value
end
local function u8_value(value)
    if type(value) ~= 'number' then return 0 end
    return value < 0 and value + 256 or value
end
local function bs_read_raw(bs)
    local total_bytes = raknetBitStreamGetNumberOfBytesUsed(bs) or 0
    local bytes = {}
    raknetBitStreamResetReadPointer(bs)
    for index = 1, total_bytes do
        local value = raknetBitStreamReadInt8(bs)
        if value == nil then break end
        bytes[index] = u8_value(value)
    end
    raknetBitStreamResetReadPointer(bs)
    return bytes
end
local function read_packet_string(bs)
    local length = raknetBitStreamReadInt16(bs)
    if not length or length <= 0 then return '' end
    local encoding_flag = raknetBitStreamReadInt8(bs)
    if encoding_flag == nil then return '' end
    if encoding_flag ~= 0 then
        return raknetBitStreamDecodeString(bs, length + encoding_flag) or ''
    end
    return raknetBitStreamReadString(bs, length) or ''
end
local function send_close_packet(interface_id, sub_id)
    local bs = raknetNewBitStream()
    raknetBitStreamWriteInt8(bs, PACKET_ID)
    raknetBitStreamWriteInt8(bs, PACKET_OUT)
    raknetBitStreamWriteInt8(bs, interface_id)
    raknetBitStreamWriteInt32(bs, 0)
    raknetBitStreamWriteInt32(bs, sub_id)
    raknetBitStreamWriteInt16(bs, 2)
    raknetBitStreamWriteInt8(bs, 0)
    raknetBitStreamWriteInt8(bs, 123)
    raknetBitStreamWriteInt8(bs, 125)
    raknetSendBitStreamEx(bs, 7, 0, 0)
    raknetDeleteBitStream(bs)
end
local function is_skip_cef_packet(bs)
    local raw = bs_read_raw(bs)
    if #raw < 4 then return false end
    return raw[2] == PACKET_IN and raw[3] == SKIP_CEF_IFACE and raw[4] == SKIP_CEF_SUB
end
local function is_hide_down_packet(bs)
    raknetBitStreamResetReadPointer(bs)
    if raknetBitStreamReadInt8(bs) ~= PACKET_ID then return false end
    if raknetBitStreamReadInt8(bs) ~= PACKET_IN then return false end
    if u8_value(raknetBitStreamReadInt8(bs)) ~= HIDE_DOWN_IFACE then return false end
    if u8_value(raknetBitStreamReadInt8(bs)) ~= HIDE_DOWN_SUB then return false end
    local payload = read_packet_string(bs)
    raknetBitStreamResetReadPointer(bs)
    return payload ~= ''
        and payload:find('"styleInt"%s*:') ~= nil
        and payload:find('"title"%s*:') ~= nil
        and payload:find('"text"%s*:') ~= nil
        and payload:find('"duration"%s*:') ~= nil
end
local function is_task_completed_text(text)
    local normalized = tostring(text or ''):lower()
    normalized = normalized:gsub('{......}', ''):gsub('%s+', ' ')
    return normalized:find('задача завершена', 1, true) ~= nil
        or normalized:find('task completed', 1, true) ~= nil
end
local function is_hide_down_text_active(text)
    return is_hide_down_blocking and is_task_completed_text(text)
end
local function OpenUrl(url)
    if MONET_VERSION then
        ffi.cdef[[void _Z12AND_OpenLinkPKc(const char* link);]]
        local gta = ffi.load('GTASA')
        gta._Z12AND_OpenLinkPKc(url)
    else
        os.execute('explorer ' .. url)
    end
end
function imgui.ClickableText(text)
    local linkColor = imgui.ImVec4(0.4, 0.7, 1.0, 1.0)
    local hoverColor = imgui.ImVec4(0.6, 0.85, 1.0, 1.0)
    imgui.PushStyleColor(imgui.Col.Text, linkColor)
    imgui.Text(text)
    local isHovered = imgui.IsItemHovered()
    if isHovered then
        imgui.SetMouseCursor(imgui.MouseCursor.Hand)
        local min = imgui.GetItemRectMin()
        local max = imgui.GetItemRectMax()
        imgui.GetWindowDrawList():AddLine(
            imgui.ImVec2(min.x, max.y),
            imgui.ImVec2(max.x, max.y),
            imgui.GetColorU32Vec4(hoverColor),
            1.0
        )
        imgui.PopStyleColor(1)
        imgui.SetTooltip(u8'Нажмите, чтобы открыть')
    else
        imgui.PopStyleColor(1)
    end
    return imgui.IsItemClicked()
end
local function apply_style()
    local style = imgui.GetStyle()
    local scale = MONET_DPI_SCALE or 1
    style.WindowRounding = 10 * scale
    style.ChildRounding = 10 * scale
    style.FrameRounding = 8 * scale
    style.GrabRounding = 8 * scale
    style.ScrollbarRounding = 8 * scale
    style.WindowBorderSize = 1
    style.ChildBorderSize = 1
    style.FrameBorderSize = 0
    style.WindowPadding = imgui.ImVec2(12 * scale, 12 * scale)
    style.FramePadding = imgui.ImVec2(12 * scale, 8 * scale)
    style.ItemSpacing = imgui.ImVec2(8 * scale, 8 * scale)
    style.ItemInnerSpacing = imgui.ImVec2(8 * scale, 6 * scale)
    style.ScrollbarSize = 0
    style.Colors[imgui.Col.WindowBg] = palette.window_bg
    style.Colors[imgui.Col.TitleBg] = palette.title_bg
    style.Colors[imgui.Col.TitleBgActive] = palette.title_bg
    style.Colors[imgui.Col.Border] = palette.border
    style.Colors[imgui.Col.Text] = palette.text
    style.Colors[imgui.Col.TextDisabled] = palette.text_dim
    style.Colors[imgui.Col.ChildBg] = palette.child_bg
    style.Colors[imgui.Col.Button] = palette.title_bg
    style.Colors[imgui.Col.ButtonHovered] = imgui.ImVec4(0.82, 0.87, 0.96, 1.00)
    style.Colors[imgui.Col.ButtonActive] = imgui.ImVec4(0.77, 0.83, 0.95, 1.00)
    style.Colors[imgui.Col.Header] = palette.title_bg
    style.Colors[imgui.Col.HeaderHovered] = imgui.ImVec4(0.82, 0.87, 0.96, 1.00)
    style.Colors[imgui.Col.HeaderActive] = imgui.ImVec4(0.77, 0.83, 0.95, 1.00)
    style.Colors[imgui.Col.CheckMark] = palette.switch_knob
end
local function draw_switch(id, value)
    local scale = MONET_DPI_SCALE or 1
    local width = 52 * scale
    local height = 30 * scale
    local radius = height * 0.5
    local draw_list = imgui.GetWindowDrawList()
    local position = imgui.GetCursorScreenPos()
    imgui.InvisibleButton(id, imgui.ImVec2(width, height))
    if imgui.IsItemClicked() then value = not value end
    local background = value and palette.switch_on or palette.switch_off
    local knob_offset = value and (width - radius) or radius
    local knob_position = imgui.ImVec2(position.x + knob_offset, position.y + radius)
    draw_list:AddRectFilled(position, imgui.ImVec2(position.x + width, position.y + height), to_u32(background), radius)
    draw_list:AddCircleFilled(knob_position, radius - (4 * scale), to_u32(palette.switch_knob), 24)
    return value
end
local function get_default_window_metrics()
    local scale = MONET_DPI_SCALE or 1
    local screen_x, screen_y = getScreenResolution()
    local width = clamp(math.floor(screen_x * 0.86), math.floor(820 * scale), math.floor(1180 * scale))
    local height = clamp(math.floor(screen_y * 0.50), math.floor(260 * scale), math.floor(340 * scale))
    if width > screen_x - (24 * scale) then width = screen_x - (24 * scale) end
    if height > screen_y - (24 * scale) then height = screen_y - (24 * scale) end
    return width, height
end
local function apply_toggle_side_effects(config_key, enabled)
    if config_key == 'hide_down_notify' and not enabled then
        is_hide_down_blocking = false
        is_hide_down_flooding = false
    end
    if config_key == 'skip_cef_notify' and not enabled then
        is_skip_cef_closing = false
    end
end
local function save_window_state(pos_x, pos_y, width, height)
    if config.pos_x == pos_x and config.pos_y == pos_y
        and config.win_width == width and config.win_height == height then
        return
    end
    config.pos_x = pos_x
    config.pos_y = pos_y
    config.win_width = width
    config.win_height = height
    local now = os.clock()
    if now - last_window_save_time >= 0.25 then
        save_config()
        last_window_save_time = now
    end
end
local function render_feature_card(id, title, description, config_key)
    local scale = MONET_DPI_SCALE or 1
    local pad_x = 12 * scale
    local pad_y = 8 * scale
    local gap = 2 * scale
    local line_h = imgui.GetTextLineHeight()
    local switch_height = 30 * scale
    local text_height = line_h + gap + line_h + gap + line_h
    local card_height = math.max(text_height + pad_y * 2, switch_height + pad_y * 2)
    local enabled = config[config_key]
    local status_color = enabled and palette.success or palette.text_dim
    local status_text = enabled and u8'Включено' or u8'Выключено'
    local style = imgui.GetStyle()
    local prev_window_padding = imgui.ImVec2(style.WindowPadding.x, style.WindowPadding.y)
    style.WindowPadding = imgui.ImVec2(pad_x, pad_y)
    imgui.PushStyleColor(imgui.Col.ChildBg, palette.child_bg)
    imgui.PushStyleColor(imgui.Col.Border, palette.border)
    imgui.BeginChild(id, imgui.ImVec2(-1, card_height), true, imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse)
    local switch_width = 52 * scale
    local win_w = imgui.GetWindowWidth()
    local switch_x = win_w - switch_width - pad_x
    local switch_y = math.max(pad_y, (card_height - switch_height) * 0.5)
    local base_y = imgui.GetCursorPosY()
    imgui.TextColored(palette.text, u8(title))
    imgui.SetCursorPosY(base_y + line_h + gap)
    imgui.TextColored(status_color, status_text)
    imgui.SetCursorPosY(base_y + line_h + gap + line_h + gap)
    imgui.PushTextWrapPos(pad_x + win_w - switch_width - pad_x * 2 - 8 * scale)
    imgui.TextWrapped(u8(description))
    imgui.PopTextWrapPos()
    imgui.SetCursorPos(imgui.ImVec2(switch_x, switch_y))
    local new_value = draw_switch('##' .. id, enabled)
    if new_value ~= enabled then
        config[config_key] = new_value
        apply_toggle_side_effects(config_key, new_value)
        save_config()
    end
    imgui.EndChild()
    imgui.PopStyleColor(2)
    style.WindowPadding = prev_window_padding
end
local function render_main_window()
    local scale = MONET_DPI_SCALE or 1
    local def_width, def_height = get_default_window_metrics()
    local width = config.win_width > 0 and config.win_width or def_width
    local height = def_height
    local screen_x, screen_y = getScreenResolution()
    if not window_pos_set then
        if config.pos_x >= 0 and config.pos_y >= 0 then
            imgui.SetNextWindowPos(imgui.ImVec2(config.pos_x, config.pos_y), imgui.Cond.Always)
        else
            imgui.SetNextWindowPos(imgui.ImVec2(screen_x * 0.5, screen_y * 0.5), imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
        end
        imgui.SetNextWindowSize(imgui.ImVec2(width, height), imgui.Cond.Always)
        window_pos_set = true
    end
    local title = u8'Skip Notify Plus##skip_notify_plus'
    local flags = imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse
    window_open[0] = menu_visible
    if imgui.Begin(title, window_open, flags) then
        local pos = imgui.GetWindowPos()
        local size = imgui.GetWindowSize()
        save_window_state(math.floor(pos.x), math.floor(pos.y), math.floor(size.x), math.floor(size.y))
        imgui.TextColored(palette.text, u8'Настройки уведомлений ')
        imgui.SameLine(nil, 0)
        imgui.TextColored(palette.text, '| Author: ')
        imgui.SameLine(nil, 0)
        if imgui.ClickableText('Charlie_Deep') then
            OpenUrl('https://t.me/rakbotik')
        end
        imgui.Separator()
        render_feature_card('skip_cef_card', 'Skip CEF Notify', 'Скрывает уведомления с персонажами в левом нижнем углу.', 'skip_cef_notify')
        imgui.Dummy(imgui.ImVec2(0, 2 * scale))
        render_feature_card('hide_down_card', 'Hide Down Notify', 'Скрывает все нижние уведомления.', 'hide_down_notify')
        imgui.Dummy(imgui.ImVec2(0, 4 * scale))
        imgui.Separator()
        imgui.Dummy(imgui.ImVec2(0, 2 * scale))
        imgui.TextColored(palette.text, u8'Если понравился скрипт, оставь отзыв: ')
        imgui.SameLine(nil, 0)
        if imgui.ClickableText('app.arzmod.com/mod/skipnotify') then
            OpenUrl('https://app.arzmod.com/mod/skipnotify')
        end
    end
    imgui.End()
    if not window_open[0] then
        menu_visible = false
        window_open[0] = true
        save_config()
    end
end
local function start_skip_cef_close()
    if is_skip_cef_closing then return end
    is_skip_cef_closing = true
    lua_thread.create(function()
        for _ = 1, 10 do
            if not config.skip_cef_notify then break end
            send_close_packet(SKIP_CEF_IFACE, SKIP_CEF_SUB)
            wait(50)
        end
        is_skip_cef_closing = false
    end)
end
local function start_hide_down_close()
    if is_hide_down_flooding then return end
    is_hide_down_flooding = true
    lua_thread.create(function()
        local attempts = 0
        while is_hide_down_blocking and attempts < HIDE_DOWN_MAX_CLOSES do
            attempts = attempts + 1
            send_close_packet(HIDE_DOWN_IFACE, HIDE_DOWN_SUB)
            wait(0)
        end
        is_hide_down_flooding = false
        if attempts >= HIDE_DOWN_MAX_CLOSES then
            is_hide_down_blocking = false
        end
    end)
end
local function toggle_menu()
    menu_visible = not menu_visible
    if menu_visible then
        window_open[0] = true
        window_pos_set = false
    else
        save_config()
    end
end
imgui.OnInitialize(function()
    apply_style()
end)
local main_frame = imgui.OnFrame(
    function() return menu_visible end,
    render_main_window
)
main_frame.HideCursor = false
main_frame.LockPlayer = false
function onReceivePacket(id, bs)
    if id ~= PACKET_ID then return end
    if config.skip_cef_notify and is_skip_cef_packet(bs) then
        start_skip_cef_close()
        return false
    end
    if config.hide_down_notify and is_hide_down_packet(bs) then
        is_hide_down_blocking = true
        start_hide_down_close()
        return false
    end
end
function sampev.onDisplayGameText(_, _, text)
    if is_hide_down_text_active(text) then
        is_hide_down_blocking = false
        return false
    end
end
function sampev.onShowTextDraw(_, data)
    local text = data and data.text or ''
    if is_hide_down_text_active(text) then
        is_hide_down_blocking = false
        return false
    end
end
function sampev.onTextDrawSetString(_, text)
    if is_hide_down_text_active(text) then
        is_hide_down_blocking = false
        return false
    end
end
function main()
    if not isSampLoaded() or not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(100) end
    load_config()
    sampRegisterChatCommand('notify', toggle_menu)
    while true do
        if is_hide_down_blocking and config.hide_down_notify and not is_hide_down_flooding then
            start_hide_down_close()
        end
        wait(0)
    end
end
