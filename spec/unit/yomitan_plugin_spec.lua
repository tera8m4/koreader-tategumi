-- Integration specs for plugins/yomitan.koplugin inside a ReaderUI.
describe("Yomitan plugin", function()
    local DocumentRegistry, ReaderUI, UIManager, Screen
    local readerui, epub_path

    local XHTML = [[<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="ja" lang="ja">
<head><title>テスト</title></head>
<body><p>彼は<ruby>打<rt>う</rt></ruby>ち込んでいませんでした。それから</p></body>
</html>]]

    local function buildEpub(path)
        local writer = require("ffi/archiver").Writer:new()
        assert.is_true(writer:open(path, "epub"))
        assert.is_true(writer:addFileFromMemory("mimetype", "application/epub+zip"))
        assert.is_true(writer:addFileFromMemory("META-INF/container.xml", [[<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>]]))
        assert.is_true(writer:addFileFromMemory("book.opf", [[<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="id">yomitan-spec</dc:identifier><dc:title>テスト</dc:title><dc:language>ja</dc:language>
</metadata>
<manifest><item id="c" href="c.xhtml" media-type="application/xhtml+xml"/></manifest>
<spine><itemref idref="c"/></spine>
</package>]]))
        assert.is_true(writer:addFileFromMemory("c.xhtml", XHTML))
        writer:close()
    end

    setup(function()
        require("commonrequire")
        -- Like PluginLoader:loadPlugins(), for modules required after loading.
        package.path = "plugins/yomitan.koplugin/?.lua;" .. package.path
        disable_plugins()
        load_plugin("yomitan.koplugin")
        local PluginLoader = require("pluginloader")
        for _, plugin in ipairs(PluginLoader.enabled_plugins) do
            if plugin.name == "yomitan" then
                -- Use the converted Yomitan test dictionary.
                plugin.getDataDir = function() return "spec/front/unit/yomitan" end
            end
        end
        DocumentRegistry = require("document/documentregistry")
        ReaderUI = require("apps/reader/readerui")
        UIManager = require("ui/uimanager")
        Screen = require("device").screen

        epub_path = os.tmpname()
        os.remove(epub_path)
        epub_path = epub_path .. ".epub"
        buildEpub(epub_path)
        readerui = ReaderUI:new{
            dimen = Screen:getSize(),
            document = DocumentRegistry:openDocument(epub_path),
        }
    end)

    teardown(function()
        ReaderUI.instance = readerui
        readerui:closeDocument()
        readerui:onClose()
        os.remove(epub_path)
    end)

    it("takes over Japanese lookups", function()
        assert.is_truthy(readerui.yomitan)
        assert.is_true(readerui.yomitan:isActive())
        assert.are.equal(readerui.yomitan, readerui.dictionary.lookup_backend)
        assert.is_true(readerui.yomitan:canLookup("打つ"))
        assert.is_false(readerui.yomitan:canLookup("test"))
    end)

    it("selects the longest match without the furigana", function()
        local hits = readerui.document:findAllText("打", false, 0, 1, false)
        assert.is_truthy(hits and hits[1])
        local pos0 = hits[1].start
        local selection = readerui.languagesupport:improveWordSelection({
            text = "打",
            pos0 = pos0,
            pos1 = readerui.document:getNextVisibleChar(pos0),
        })
        assert.is_truthy(selection)
        assert.are.equal("打ち込んでいませんでした", selection.text)
        assert.are.equal(pos0, selection.pos0)
        assert.is_true(#selection.sboxes > 0)
    end)

    it("shows Yomitan entries in the dictionary popup", function()
        ReaderUI.instance = readerui
        UIManager:show(readerui)
        readerui.dictionary:stardictLookup("打ち込んでいませんでした")
        local window = readerui.dictionary.dict_window
        assert.is_truthy(window)
        local first = window.results[1]
        assert.are.equal("打ち込む【うちこむ】", first.word)
        assert.are.equal("Test Dictionary", first.dict)
        assert.is_true(first.is_html)
        assert.is_truthy(first.definition:find("-ます", 1, true))
        UIManager:close(window)
        UIManager:close(readerui)
    end)
end)
