obs = obslua

source_name = ""
auto_monitor = false
last_signature = nil

TAGS = {
    "title",
    "artist",
    "album",
    "album_artist",
    "now_playing",
    "track_number",
    "date",
    "publisher",
    "encoded_by",
    "url"
}

local function safe_string(v)
    if v == nil then
        return ""
    end
    return tostring(v)
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
        value = safe_string(obs.calldata_string(cd, "tag_data"))
    end

    obs.calldata_destroy(cd)
    return value, ok
end

local function identity_of(source)
    local title = get_metadata(source, "title")
    local artist = get_metadata(source, "artist")
    local now_playing = get_metadata(source, "now_playing")
    return safe_string(title) .. "\n" .. safe_string(artist) .. "\n" .. safe_string(now_playing)
end

local function collect_snapshot(source)
    -- 曲切替の境界で旧曲/新曲のタグが混ざらないよう、
    -- 取得前後の主要メタデータが一致することを確認する。
    local before = identity_of(source)

    local values = {}
    local supported = false
    local any_value = false

    for _, tag in ipairs(TAGS) do
        local value, ok = get_metadata(source, tag)
        values[tag] = value

        if ok then
            supported = true
        end
        if value ~= "" then
            any_value = true
        end
    end

    local after = identity_of(source)

    if before ~= after then
        return nil, supported, any_value, false
    end

    return values, supported, any_value, true
end

local function read_all_metadata(force_log)
    if source_name == nil or source_name == "" then
        if force_log then
            obs.script_log(obs.LOG_WARNING,
                "[VLC Metadata Probe] VLCソースが選択されていません。")
        end
        return
    end

    local source = obs.obs_get_source_by_name(source_name)
    if source == nil then
        if force_log then
            obs.script_log(obs.LOG_WARNING,
                "[VLC Metadata Probe] ソースが見つかりません: " .. source_name)
        end
        return
    end

    local source_id = obs.obs_source_get_unversioned_id(source)
    if source_id ~= "vlc_source" then
        obs.script_log(obs.LOG_WARNING,
            "[VLC Metadata Probe] 選択されたソースはVLCビデオソースではありません: "
            .. safe_string(source_id))
        obs.obs_source_release(source)
        return
    end

    local values, supported, any_value, stable = collect_snapshot(source)
    obs.obs_source_release(source)

    if not supported then
        if force_log then
            obs.script_log(obs.LOG_ERROR,
                "[VLC Metadata Probe] get_metadata を呼び出せませんでした。")
        end
        return
    end

    -- 曲切替の瞬間に取得内容が変化した場合は次回へ回す。
    if not stable then
        return
    end

    -- 自動監視では、曲間の一瞬の「全項目空」をログに出さない。
    -- 手動ボタン時は診断のため空でも表示する。
    if not force_log and not any_value then
        -- 無音/停止/曲間を挟んだあと同じ曲が再生されても、
        -- 再びログへ出せるよう直前シグネチャをリセットする。
        last_signature = nil
        return
    end

    local signature_parts = {}
    for _, tag in ipairs(TAGS) do
        table.insert(signature_parts, tag .. "=" .. safe_string(values[tag]))
    end
    local signature = table.concat(signature_parts, "\n")

    if force_log or signature ~= last_signature then
        last_signature = signature

        obs.script_log(obs.LOG_INFO, "========== VLC Metadata Probe ==========")
        obs.script_log(obs.LOG_INFO, "source       : " .. source_name)

        for _, tag in ipairs(TAGS) do
            local value = safe_string(values[tag])
            if value == "" then
                value = "(empty)"
            end
            obs.script_log(obs.LOG_INFO, string.format("%-13s: %s", tag, value))
        end

        obs.script_log(obs.LOG_INFO, "========================================")
    end
end

function monitor_tick()
    read_all_metadata(false)
end

function test_now(props, property)
    read_all_metadata(true)
    return false
end

function script_description()
    return [[
OBS VLCビデオソースで現在再生中のメディアから、
title / artist / album / now_playing などのメタデータを取得して
OBSのスクリプトログへ表示する診断用Luaです。

通常は「今すぐメタデータを取得」ボタンだけで使用します。
自動監視は任意でONにできますが、OBS再起動時には必ずOFFへ戻ります。

m3uプレイリスト、またはVLCビデオソースへ直接追加した音声ファイルの
実際の楽曲タグを確認できます。
曲切替境界での一時的な空データや、旧曲/新曲のタグ混在を避ける処理を入れています。
]]
end

function script_defaults(settings)
    -- 診断ツールなので、既定ではログ監視を行わない。
    obs.obs_data_set_default_bool(settings, "auto_monitor", false)
end

function script_properties()
    local props = obs.obs_properties_create()

    local list = obs.obs_properties_add_list(
        props,
        "source",
        "VLCビデオソース",
        obs.OBS_COMBO_TYPE_LIST,
        obs.OBS_COMBO_FORMAT_STRING
    )

    local sources = obs.obs_enum_sources()
    if sources ~= nil then
        for _, source in ipairs(sources) do
            local source_id = obs.obs_source_get_unversioned_id(source)
            if source_id == "vlc_source" then
                local name = obs.obs_source_get_name(source)
                obs.obs_property_list_add_string(list, name, name)
            end
        end
        obs.source_list_release(sources)
    end

    obs.obs_properties_add_bool(
        props,
        "auto_monitor",
        "自動監視（1秒ごと／OBS再起動でOFF）"
    )

    -- OBS 32.2.xではC API側の add_button はdeprecatedだが、
    -- OBS公式ドキュメント上、スクリプトではこの関数を使用する。
    obs.obs_properties_add_button(
        props,
        "test_now",
        "今すぐメタデータを取得",
        test_now
    )

    return props
end

function script_update(settings)
    source_name = obs.obs_data_get_string(settings, "source")
    auto_monitor = obs.obs_data_get_bool(settings, "auto_monitor")
    last_signature = nil

    obs.timer_remove(monitor_tick)

    if auto_monitor then
        obs.timer_add(monitor_tick, 1000)
    end
end

function script_load(settings)
    -- 診断用の自動監視はセッション限定。
    -- OBS再起動やスクリプト再読み込み時に、勝手にログ監視を再開しない。
    obs.timer_remove(monitor_tick)
    auto_monitor = false
    obs.obs_data_set_bool(settings, "auto_monitor", false)
end

function script_unload()
    obs.timer_remove(monitor_tick)
end
