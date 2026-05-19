-- xray_terms_spec.lua
require("spec/spec_helper")

describe("xray_terms", function()
    local xray_data
    local xray_aihelper
    local xray_lookupmanager

    setup(function()
        xray_data = require("xray_data")
        xray_aihelper = require("xray_aihelper")
        xray_lookupmanager = require("xray_lookupmanager")
    end)

    describe("isNonFictionBook", function()
        it("should identify non-fiction from metadata", function()
            local props = {
                category = "Computers & Technology",
                Series = nil
            }
            assert.is_true(xray_data:isNonFictionBook(props, ""))
        end)

        it("should identify non-fiction from acronym density", function()
            local text = "The CPU and GPU communicate via the PCI bus using DMA and IRQ signals. The BIOS initializes the RAM."
            assert.is_true(xray_data:isNonFictionBook({}, text))
        end)

        it("should identify fiction despite some acronyms", function()
            local text = "She said hello to the CIA agent who worked at the FBI. They went to the USA."
            assert.is_false(xray_data:isNonFictionBook({}, text))
        end)
    end)

    describe("AIHelper placeholders", function()
        it("should replace {NUM_TERMS} and {MAX_TERM_DEF}", function()
            xray_aihelper.settings = {
                term_def_len = 123
            }
            xray_aihelper.prompts = {
                test_prompt = "Fetch {NUM_TERMS} terms with max {MAX_TERM_DEF} chars."
            }
            local result = xray_aihelper:createPrompt(nil, nil, nil, "test_prompt")
            assert.is_true(result:find("15 terms") ~= nil)
            assert.is_true(result:find("123 chars") ~= nil)
        end)
    end)

    describe("LookupManager with terms", function()
        it("should find terms", function()
            local mock_plugin = {
                characters = {},
                historical_figures = {},
                locations = {},
                terms = {
                    { name = "API", definition = "Application Programming Interface" }
                }
            }
            local lookup = xray_lookupmanager:new(mock_plugin)
            local results = lookup:lookupAll("API")
            assert.are.equal(1, #results)
            assert.are.equal("term", results[1].item_type)
            assert.are.equal("API", results[1].item.name)
        end)
    end)

    describe("Prompt generation under fiction", function()
        it("should contain world-building instructions in English prompts", function()
            xray_aihelper.settings = {
                term_def_len = 100,
                book_mode = "fiction"
            }
            -- Force English prompts for the test
            local en_prompts = require("prompts/en")
            xray_aihelper.prompts = en_prompts
            
            local result = xray_aihelper:createPrompt("Title", "Author", {}, "comprehensive_xray")
            
            assert.is_not_nil(result:find("magic systems"))
            assert.is_not_nil(result:find("world%-building"))
            assert.is_not_nil(result:find("factions"))
        end)

        it("should support world-building in more_terms prompt", function()
            xray_aihelper.settings = {
                term_def_len = 100,
                book_mode = "fiction"
            }
            local en_prompts = require("prompts/en")
            xray_aihelper.prompts = en_prompts
            
            local result = xray_aihelper:createPrompt("Title", "Author", {}, "more_terms")
            
            assert.is_not_nil(result:find("world%-building"))
            assert.is_not_nil(result:find("factions"))
        end)
    end)

    describe("Fiction World-Building Mentions Scanning", function()
        local analyzer = require("xray_chapteranalyzer")
        
        it("should correctly classify entity types and perform multi-word alias generation", function()
            local doc = {
                getTextFromXPointers = function() return "The Jedi Order was founded long ago. A Jedi must be strong." end,
                getTextFromXPointer = function() return "The Jedi Order was founded long ago. A Jedi must be strong." end
            }
            local ui = { document = doc, loc = { t = function(self, s) return s end } }
            local toc_entry = { title = "Chapter 1", page = 1, xpointer = "xp1" }
            
            local entity = {
                name = "The Jedi Order",
                definition = "An ancient monastic organization"
            }
            
            local mentions = analyzer:findMentionsInChapter(ui, entity, toc_entry, nil)
            assert.is_true(#mentions > 0)
        end)

        it("should avoid garbage plural suffix on multi-word term names", function()
            local doc = {
                getTextFromXPointers = function() return "Stark Direwolves are fierce creatures." end,
                getTextFromXPointer = function() return "Stark Direwolves are fierce creatures." end
            }
            local ui = { document = doc, loc = { t = function(self, s) return s end } }
            local toc_entry = { title = "Chapter 1", page = 1, xpointer = "xp1" }
            
            local entity = {
                name = "Stark Direwolves",
                definition = "A breed of large and intelligent wolves"
            }
            
            local mentions = analyzer:findMentionsInChapter(ui, entity, toc_entry, nil)
            assert.is_true(#mentions > 0)
        end)

        it("should support page-based synthetic TOC fallback when book has no TOC", function()
            local doc = {
                getPageCount = function() return 20 end,
                getPageText = function() return "Inside Starfleet Command we found a mysterious artifact." end
            }
            local ui = { document = doc, loc = { t = function(self, s) return s end } }
            local entity = {
                name = "Starfleet Command",
                definition = "The headquarters of Starfleet"
            }
            
            local complete_called = false
            local found_mentions = nil
            local ok, err = pcall(function()
                analyzer:scanMentionsAsync(ui, entity, {}, nil, nil, nil, function(mentions)
                    complete_called = true
                    found_mentions = mentions
                end)
            end)
            if not ok then
                print("scanMentionsAsync crashed with error: " .. tostring(err))
            end
            
            assert.is_true(complete_called)
            assert.is_not_nil(found_mentions)
            assert.is_true(#found_mentions > 0)
        end)
    end)

    describe("finalizeXRayData with glossary-only data", function()
        it("should accept glossary-only data without triggering abort", function()
            local mock_fetch = require("xray_fetch")
            local mock_plugin = {
                ui = {
                    document = {
                        file = "test_book.epub",
                        getPageCount = function() return 100 end,
                        getToc = function() return {} end
                    },
                    getCurrentPage = function() return 10 end
                },
                loc = { t = function(self, s) return s end },
                cache_manager = {
                    loadCache = function() return {} end,
                    saveCache = function() return true end
                },
                deduplicateByName = function(self, data, key) return data end,
                sortDataByFrequency = function(self, data, text, key) return data end,
                isNonNarrativeChapter = function() return false end,
                assignTimelinePages = function() end,
                sortTimelineByTOC = function() end,
                log = function() end
            }
            setmetatable(mock_plugin, { __index = mock_fetch })

            local test_data = {
                characters = {},
                locations = {},
                historical_figures = {},
                timeline = {},
                terms = {
                    { name = "Jedi", definition = "Force users" }
                },
                book_type = "fiction"
            }

            local called_abort = false
            mock_plugin.log = function(self, msg)
                if msg:find("AI returned all-empty data") then
                    called_abort = true
                end
            end

            mock_plugin:finalizeXRayData(test_data, "Test Book", "Test Author", "Some text context", false, true, 10)
            assert.is_false(called_abort)
            assert.are.equal("Test Book", mock_plugin.book_data.book_title)
            assert.are.equal(1, #mock_plugin.book_data.terms)
            assert.are.equal("Jedi", mock_plugin.book_data.terms[1].name)
        end)
    end)
end)
