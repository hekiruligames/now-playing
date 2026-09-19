obs = obslua

-- OBS VLC Now Playing v1.2
-- OBS VLC Video Source の get_metadata を使い、
-- 再生中楽曲のタグを既存のテキストソースへ表示する。

vlc_source_name = ""
text_source_name = ""

show_title = true
show_artist = true
show_album = false
show_date = false
show_genre = false

artist_mode = "album_artist_first"
separator_mode = "newline"
prefix_text = "♪ "
show_labels = false
empty_fallback = ""
clear_when_stopped = true

last_output = nil
inactive_ticks = 0

local TAGS = {
    "title",
    "artist",
    "album_artist",
    "album",
    "date",
    "genre",
    "now_playing"
}

local function safe_string(v)
    if v == nil then
        return ""
    end
    return tostring(v)
end

local function trim(s)
    s = safe_string(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function get_metadata(source, tag_id)
    local ph = obs.obs_source_get_proc_handler(source)
    if ph == nil then
        return "", false
    end

    local cd = obs.calldata_create()
    if cd == nil then
        return "", false
    end

    obs.calldata_set_string(cd, "tag_id", tag_id)
    local ok = obs.proc_handler_call(ph, "get_metadata", cd)

    local value = ""
    if ok then
        value = trim(obs.calldata_string(cd, "tag_data"))
    end

    obs.calldata_destroy(cd)
    return value, ok
end

local function identity_of(source)
    local title = get_metadata(source, "title")
    local artist = get_metadata(source, "artist")
    local album_artist = get_metadata(source, "album_artist")
    local now_playing = get_metadata(source, "now_playing")

    return table.concat({
        safe_string(title),
        safe_string(artist),
        safe_string(album_artist),
        safe_string(now_playing)
    }, "\n")
end

local function collect_snapshot(source)
    -- 曲切替中に旧曲と新曲のタグが混ざるのを避けるため、
    -- 取得前後の主要情報が同じか確認する。
    local before = identity_of(source)

    local values = {}
    local supported = false

    for _, tag in ipairs(TAGS) do
        local value, ok = get_metadata(source, tag)
        values[tag] = value
        if ok then
            supported = true
        end
    end

    local after = identity_of(source)

    if before ~= after then
        return nil, supported, false
    end

    return values, supported, true
end

local function selected_artist(values)
    local artist = trim(values.artist)
    local album_artist = trim(values.album_artist)

    if artist_mode == "artist_first" then
        if artist ~= "" then return artist end
        return album_artist
    elseif artist_mode == "artist_only" then
        return artist
    elseif artist_mode == "album_artist_only" then
        return album_artist
    else
        -- default: album_artist_first
        if album_artist ~= "" then return album_artist end
        return artist
    end
end

local function separator_string()
    if separator_mode == "slash" then
        return " / "
    elseif separator_mode == "dash" then
        return " - "
    elseif separator_mode == "pipe" then
        return " | "
    else
        return "\n"
    end
end

local function add_item(items, seen, label, value)
    value = trim(value)
    if value == "" then
        return
    end

    -- 同一内容の重複表示を避ける。
    if seen[value] then
        return
    end
    seen[value] = true

    if show_labels then
        table.insert(items, label .. ": " .. value)
    else
        table.insert(items, value)
    end
end

local function build_display(values)
    local items = {}
    local seen = {}

    if show_title then
        -- ローカル音源では title が第一候補。
        -- title が無い場合、ストリーム等で使われる now_playing を代替候補にする。
        local title = trim(values.title)
        if title == "" then
            title = trim(values.now_playing)
        end
        add_item(items, seen, "曲名", title)
    end

    if show_artist then
        add_item(items, seen, "アーティスト", selected_artist(values))
    end

    if show_album then
        add_item(items, seen, "アルバム", values.album)
    end

    if show_date then
        add_item(items, seen, "年", values.date)
    end

    if show_genre then
        add_item(items, seen, "ジャンル", values.genre)
    end

    if #items == 0 then
        return empty_fallback
    end

    return prefix_text .. table.concat(items, separator_string())
end

local function set_text(text)
    text = safe_string(text)

    if last_output == text then
        return
    end

    if text_source_name == nil or text_source_name == "" then
        return
    end

    local target = obs.obs_get_source_by_name(text_source_name)
    if target == nil then
        return
    end

    local settings = obs.obs_data_create()
    obs.obs_data_set_string(settings, "text", text)
    obs.obs_source_update(target, settings)
    obs.obs_data_release(settings)
    obs.obs_source_release(target)

    last_output = text
end

local function state_is_inactive(state)
    return state == obs.OBS_MEDIA_STATE_NONE
        or state == obs.OBS_MEDIA_STATE_STOPPED
        or state == obs.OBS_MEDIA_STATE_ENDED
        or state == obs.OBS_MEDIA_STATE_ERROR
end

local function refresh_display(force)
    -- 表示先が明示選択されるまでは、絶対にテキストソースを書き換えない。
    if text_source_name == nil or text_source_name == "" then
        if force then
            obs.script_log(obs.LOG_WARNING,
                "[VLC Now Playing] 表示先テキストソースが選択されていません。")
        end
        return
    end

    if vlc_source_name == nil or vlc_source_name == "" then
        if force then
            obs.script_log(obs.LOG_WARNING,
                "[VLC Now Playing] VLCビデオソースが選択されていません。")
        end
        return
    end

    local source = obs.obs_get_source_by_name(vlc_source_name)
    if source == nil then
        if force then
            obs.script_log(obs.LOG_WARNING,
                "[VLC Now Playing] VLCソースが見つかりません: " .. vlc_source_name)
        end
        return
    end

    local source_id = obs.obs_source_get_unversioned_id(source)
    if source_id ~= "vlc_source" then
        if force then
            obs.script_log(obs.LOG_WARNING,
                "[VLC Now Playing] 選択されたソースはVLCビデオソースではありません。")
        end
        obs.obs_source_release(source)
        return
    end

    local state = obs.obs_source_media_get_state(source)

    if state_is_inactive(state) then
        inactive_ticks = inactive_ticks + 1

        -- 曲間の一瞬の停止状態による表示ちらつきを避ける。
        if clear_when_stopped and inactive_ticks >= 2 then
            set_text("")
        end

        obs.obs_source_release(source)
        return
    else
        inactive_ticks = 0
    end

    local values, supported, stable = collect_snapshot(source)
    obs.obs_source_release(source)

    if not supported then
        if force then
            obs.script_log(obs.LOG_ERROR,
                "[VLC Now Playing] このソースでは get_metadata を利用できません。")
        end
        return
    end

    -- 曲切替の途中なら次回の監視へ回す。
    if not stable or values == nil then
        return
    end

    local text = build_display(values)
    set_text(text)

    if force then
        obs.script_log(obs.LOG_INFO,
            "[VLC Now Playing] 表示を更新しました: " ..
            (text ~= "" and text:gsub("\n", " / ") or "(empty)"))
    end
end

function monitor_tick()
    refresh_display(false)
end

function refresh_now_button(props, property)
    last_output = nil
    refresh_display(true)
    return false
end

function script_description()
    return [[
VLCビデオソースで現在再生中の楽曲メタデータを取得し、
指定したOBSテキストソースへ自動表示します。

・VLCビデオソースのプレイリストに対応
  （m3u / 複数の音声ファイルを直接追加する構成の両方に対応）
・曲名 / アーティスト / アルバム / 年 / ジャンルを選択可能
・空タグは自動除外
・アーティストは Artist と Album Artist の優先順を選択可能
・表示先テキストソースはシーン別に整理
・表示先は初期状態「（選択なし）」で、安全のため自動選択しない
・曲切替時の一時的な空データやタグ混在を抑制
]]
end

function script_defaults(settings)
    -- 表示先は安全のため必ず未選択を初期値にする。
    obs.obs_data_set_default_string(settings, "text_source", "")

    obs.obs_data_set_default_bool(settings, "show_title", true)
    obs.obs_data_set_default_bool(settings, "show_artist", true)
    obs.obs_data_set_default_bool(settings, "show_album", false)
    obs.obs_data_set_default_bool(settings, "show_date", false)
    obs.obs_data_set_default_bool(settings, "show_genre", false)

    obs.obs_data_set_default_string(settings, "artist_mode", "album_artist_first")
    obs.obs_data_set_default_string(settings, "separator_mode", "newline")
    obs.obs_data_set_default_string(settings, "prefix_text", "♪ ")
    obs.obs_data_set_default_bool(settings, "show_labels", false)
    obs.obs_data_set_default_string(settings, "empty_fallback", "")
    obs.obs_data_set_default_bool(settings, "clear_when_stopped", true)
end

local function add_vlc_sources(list)
    local sources = obs.obs_enum_sources()
    if sources == nil then
        return
    end

    for _, source in ipairs(sources) do
        local source_id = obs.obs_source_get_unversioned_id(source)
        if source_id == "vlc_source" then
            local name = obs.obs_source_get_name(source)
            obs.obs_property_list_add_string(list, name, name)
        end
    end

    obs.source_list_release(sources)
end

local function is_supported_text_source(source)
    local source_id = safe_string(obs.obs_source_get_unversioned_id(source))
    return source_id == "text_ft2_source"
        or source_id == "text_gdiplus"
        or string.find(source_id, "text_ft2_source", 1, true) ~= nil
        or string.find(source_id, "text_gdiplus", 1, true) ~= nil
end

local function collect_text_sources_from_items(items, result, seen)
    if items == nil then
        return
    end

    for _, item in ipairs(items) do
        local source = obs.obs_sceneitem_get_source(item)

        if source ~= nil and is_supported_text_source(source) then
            local name = safe_string(obs.obs_source_get_name(source))
            if name ~= "" and not seen[name] then
                table.insert(result, name)
                seen[name] = true
            end
        end

        -- グループ内のテキストソースも同じシーン配下として列挙する。
        if obs.obs_sceneitem_is_group(item) then
            local group_items = obs.obs_sceneitem_group_enum_items(item)
            if group_items ~= nil then
                collect_text_sources_from_items(group_items, result, seen)
                obs.sceneitem_list_release(group_items)
            end
        end
    end
end

local function add_scene_header(list, scene_name, header_no)
    local label = "── " .. scene_name .. " ──"
    local value = "__scene_header_" .. tostring(header_no)

    local idx = obs.obs_property_list_add_string(list, label, value)
    obs.obs_property_list_item_disable(list, idx, true)
end

local function add_text_sources(list)
    -- 先頭を必ず空値にする。OBSが最初の実ソースを自動選択するのを防ぐ。
    obs.obs_property_list_add_string(list, "（選択なし）", "")

    local scenes = obs.obs_frontend_get_scenes()
    if scenes == nil then
        return
    end

    local header_no = 0

    for _, scene_source in ipairs(scenes) do
        local scene = obs.obs_scene_from_source(scene_source)

        if scene ~= nil then
            local scene_name = safe_string(obs.obs_source_get_name(scene_source))
            local items = obs.obs_scene_enum_items(scene)

            if items ~= nil then
                local names = {}
                local seen = {}
                collect_text_sources_from_items(items, names, seen)
                obs.sceneitem_list_release(items)

                if #names > 0 then
                    header_no = header_no + 1
                    add_scene_header(list, scene_name, header_no)

                    for _, name in ipairs(names) do
                        obs.obs_property_list_add_string(list, "    " .. name, name)
                    end
                end
            end
        end
    end

    -- Luaの obs_frontend_get_scenes() が返すリストは source_list_release() で解放する。
    obs.source_list_release(scenes)
end

function script_properties()
    local props = obs.obs_properties_create()

    local vlc_list = obs.obs_properties_add_list(
        props,
        "vlc_source",
        "VLCビデオソース",
        obs.OBS_COMBO_TYPE_LIST,
        obs.OBS_COMBO_FORMAT_STRING
    )
    add_vlc_sources(vlc_list)

    local text_list = obs.obs_properties_add_list(
        props,
        "text_source",
        "表示先テキストソース",
        obs.OBS_COMBO_TYPE_LIST,
        obs.OBS_COMBO_FORMAT_STRING
    )
    add_text_sources(text_list)

    obs.obs_properties_add_bool(props, "show_title", "曲名を表示")
    obs.obs_properties_add_bool(props, "show_artist", "アーティストを表示")
    obs.obs_properties_add_bool(props, "show_album", "アルバムを表示")
    obs.obs_properties_add_bool(props, "show_date", "年を表示")
    obs.obs_properties_add_bool(props, "show_genre", "ジャンルを表示")

    local artist_list = obs.obs_properties_add_list(
        props,
        "artist_mode",
        "アーティストの取得元",
        obs.OBS_COMBO_TYPE_LIST,
        obs.OBS_COMBO_FORMAT_STRING
    )
    obs.obs_property_list_add_string(
        artist_list, "Album Artist → Artist の順で補完", "album_artist_first")
    obs.obs_property_list_add_string(
        artist_list, "Artist → Album Artist の順で補完", "artist_first")
    obs.obs_property_list_add_string(
        artist_list, "Artist のみ", "artist_only")
    obs.obs_property_list_add_string(
        artist_list, "Album Artist のみ", "album_artist_only")

    local sep_list = obs.obs_properties_add_list(
        props,
        "separator_mode",
        "項目の区切り",
        obs.OBS_COMBO_TYPE_LIST,
        obs.OBS_COMBO_FORMAT_STRING
    )
    obs.obs_property_list_add_string(sep_list, "改行", "newline")
    obs.obs_property_list_add_string(sep_list, " / ", "slash")
    obs.obs_property_list_add_string(sep_list, " - ", "dash")
    obs.obs_property_list_add_string(sep_list, " | ", "pipe")

    obs.obs_properties_add_text(
        props,
        "prefix_text",
        "先頭に付ける文字",
        obs.OBS_TEXT_DEFAULT
    )

    obs.obs_properties_add_bool(
        props,
        "show_labels",
        "「曲名:」「アーティスト:」などの項目名を付ける"
    )

    obs.obs_properties_add_text(
        props,
        "empty_fallback",
        "タグがすべて空の場合\n（空欄可）",
        obs.OBS_TEXT_DEFAULT
    )

    obs.obs_properties_add_bool(
        props,
        "clear_when_stopped",
        "停止・終了時に表示を消す"
    )

    obs.obs_properties_add_button(
        props,
        "refresh_now",
        "今すぐ表示を更新",
        refresh_now_button
    )

    return props
end

function script_update(settings)
    vlc_source_name = obs.obs_data_get_string(settings, "vlc_source")
    text_source_name = obs.obs_data_get_string(settings, "text_source")

    show_title = obs.obs_data_get_bool(settings, "show_title")
    show_artist = obs.obs_data_get_bool(settings, "show_artist")
    show_album = obs.obs_data_get_bool(settings, "show_album")
    show_date = obs.obs_data_get_bool(settings, "show_date")
    show_genre = obs.obs_data_get_bool(settings, "show_genre")

    artist_mode = obs.obs_data_get_string(settings, "artist_mode")
    separator_mode = obs.obs_data_get_string(settings, "separator_mode")
    prefix_text = obs.obs_data_get_string(settings, "prefix_text")
    show_labels = obs.obs_data_get_bool(settings, "show_labels")
    empty_fallback = obs.obs_data_get_string(settings, "empty_fallback")
    clear_when_stopped = obs.obs_data_get_bool(settings, "clear_when_stopped")

    last_output = nil
    inactive_ticks = 0

    obs.timer_remove(monitor_tick)
    obs.timer_add(monitor_tick, 1000)

    refresh_display(false)
end

function script_load(settings)
    -- OBSはロード後に script_update() を呼ぶため、ここでは重複タイマーを作らない。
end

function script_unload()
    obs.timer_remove(monitor_tick)
end
