--[[--
Port of the term lookup path of Yomitan's Translator
(ext/js/language/translator.js) for Japanese.

Given the text following the tapped position, it generates every prefix,
every text preprocessor variant of it and every deinflection, looks all of
them up in one go, validates parts of speech, and builds grouped, sorted
dictionary entries exactly like Yomitan's "group" (default), "term" and
"split" result modes.

Dictionaries are objects providing:
  - title (string)
  - findTermsBulk(terms) -> array of rows (see yomitan/db.lua)
  - findTagMeta(name) -> {category=, order=, notes=, score=} or nil

Known deviations from Yomitan:
  - lengths are counted in Unicode code points rather than UTF-16 units;
  - the final string tie-breakers use byte order instead of Intl.Collator;
  - frequency, pitch and kanji dictionaries are not supported.

@module yomitan.translator
]]

local Japanese = require("yomitan/japanese")
local LanguageTransformer = require("yomitan/language_transformer")
local UString = require("yomitan/ustring")

local ulen = UString.len

local Translator = {}
Translator.__index = Translator

local shared_transformer

local function getTransformer()
    if not shared_transformer then
        shared_transformer = LanguageTransformer.new()
        shared_transformer:addDescriptor(require("yomitan/data/transforms_ja"))
    end
    return shared_transformer
end

--- Create a translator.
-- @tparam table args {dictionaries = {dict,...} (in priority order), json_decode = function}
function Translator.new(args)
    local o = setmetatable({}, Translator)
    o.transformer = getTransformer()
    o.json_decode = args.json_decode
    o.tag_cache = {}
    o:setDictionaries(args.dictionaries or {})
    return o
end

function Translator:setDictionaries(dictionaries)
    self.dictionaries = dictionaries
    self.dictionary_info = {}
    for i, dict in ipairs(dictionaries) do
        self.dictionary_info[dict.title] = {
            index = i - 1,
            alias = dict.alias or dict.title,
            use_deinflections = dict.use_deinflections ~= false,
            parts_of_speech_filter = dict.parts_of_speech_filter ~= false,
            dictionary = dict,
        }
    end
    self.tag_cache = {}
end

-- Helpers

local function arrayCopy(t)
    local out = {}
    for i = 1, #t do out[i] = t[i] end
    return out
end

local function arraysEqualIgnoreOrder(a, b)
    if #a ~= #b then return false end
    local counter = {}
    for _, v in ipairs(a) do counter[v] = (counter[v] or 0) + 1 end
    for _, v in ipairs(b) do
        local c = counter[v]
        if not c or c == 0 then return false end
        counter[v] = c - 1
    end
    return true
end

local function contains(list, value)
    for _, v in ipairs(list) do
        if v == value then return true end
    end
    return false
end

local function addUniqueSimple(list, new_items)
    for _, item in ipairs(new_items) do
        if not contains(list, item) then
            table.insert(list, item)
        end
    end
end

local function compareStrings(a, b)
    if a == b then return 0 end
    return a < b and -1 or 1
end

--- Stable sort (JavaScript's Array.prototype.sort is stable, table.sort is not).
local function stableSort(list, compare)
    for i, v in ipairs(list) do
        list[i] = { v = v, i = i }
    end
    table.sort(list, function(a, b)
        local c = compare(a.v, b.v)
        if c ~= 0 then return c < 0 end
        return a.i < b.i
    end)
    for i, w in ipairs(list) do
        list[i] = w.v
    end
end

local function splitField(s)
    if s == nil or s == "" then return {} end
    local out = {}
    -- JavaScript's split(' ') keeps empty items between consecutive spaces.
    local init = 1
    while true do
        local i = s:find(" ", init, true)
        if not i then
            table.insert(out, s:sub(init))
            break
        end
        table.insert(out, s:sub(init, i - 1))
        init = i + 1
    end
    return out
end
Translator.splitField = splitField

local function getNameBase(name)
    local pos = name:find(":", 1, true)
    return pos and name:sub(1, pos - 1) or name
end

local function createDeinflection(original_text, transformed_text, deinflected_text, conditions, text_processor_chains, inflection_chains)
    return {
        original_text = original_text,
        transformed_text = transformed_text,
        deinflected_text = deinflected_text,
        conditions = conditions,
        text_processor_rule_chain_candidates = text_processor_chains,
        inflection_rule_chain_candidates = inflection_chains,
        database_entries = {},
    }
end

-- Text variants

--- Ordered map helper: {keys = {...}, values = {key -> value}}.
local function newOrderedMap()
    return { keys = {}, values = {} }
end

local function orderedSet(map, key, value)
    if map.values[key] == nil then
        table.insert(map.keys, key)
    end
    map.values[key] = value
end

function Translator:_getTextVariants(text, text_processors, cache)
    local variants = newOrderedMap()
    orderedSet(variants, text, { {} })
    for _, processor in ipairs(text_processors) do
        local id = processor.id
        local new_variants = newOrderedMap()
        for _, variant in ipairs(variants.keys) do
            local current_chains = variants.values[variant]
            local level1 = cache[variant]
            if not level1 then
                level1 = {}
                cache[variant] = level1
            end
            local processed_texts = level1[id]
            if not processed_texts then
                processed_texts = processor.process(variant)
                level1[id] = processed_texts
            end
            for _, processed in ipairs(processed_texts) do
                local existing = new_variants.values[processed]
                if processed == variant then
                    orderedSet(new_variants, processed, existing or current_chains)
                else
                    local extended = {}
                    for i, chain in ipairs(current_chains) do
                        local c = arrayCopy(chain)
                        table.insert(c, id)
                        extended[i] = c
                    end
                    if existing == nil then
                        orderedSet(new_variants, processed, extended)
                    else
                        local merged = arrayCopy(existing)
                        for _, c in ipairs(extended) do table.insert(merged, c) end
                        orderedSet(new_variants, processed, merged)
                    end
                end
            end
        end
        variants = new_variants
    end
    return variants
end

-- Deinflections

function Translator:_getAlgorithmDeinflections(text)
    local deinflections = {}
    local cache = {}
    local chars = UString.chars(text)
    for length = #chars, 1, -1 do
        local raw_source = table.concat(chars, "", 1, length)
        local variants = self:_getTextVariants(raw_source, Japanese.TEXT_PREPROCESSORS, cache)
        for _, source in ipairs(variants.keys) do
            local preprocessor_chains = variants.values[source]
            for _, deinflection in ipairs(self.transformer:transform(source)) do
                local rules = {}
                for i, frame in ipairs(deinflection.trace) do
                    rules[i] = frame.transform
                end
                -- Japanese has no text postprocessors, so the transformed text
                -- is the deinflection itself and the chains are the
                -- preprocessor chains.
                table.insert(deinflections, createDeinflection(
                    raw_source, source, deinflection.text, deinflection.conditions,
                    preprocessor_chains, { { source = "algorithm", inflection_rules = rules } }))
            end
        end
    end
    return deinflections
end

--- Query all enabled dictionaries for the unique deinflected texts and attach
-- the matching rows to the deinflections whose conditions they satisfy.
function Translator:_addEntriesToDeinflections(deinflections)
    local unique_terms = {}
    local unique_arrays = {}
    local index_of = {}
    for _, deinflection in ipairs(deinflections) do
        local term = deinflection.deinflected_text
        local idx = index_of[term]
        if not idx then
            table.insert(unique_terms, term)
            idx = #unique_terms
            index_of[term] = idx
            unique_arrays[idx] = {}
        end
        table.insert(unique_arrays[idx], deinflection)
    end
    if #unique_terms == 0 then return end

    local database_entries = self:_findTermsBulk(unique_terms)
    for _, entry in ipairs(database_entries) do
        local info = self.dictionary_info[entry.dictionary]
        local definition_conditions = self.transformer:getConditionFlagsFromPartsOfSpeech(entry.rules)
        for _, deinflection in ipairs(unique_arrays[entry.index]) do
            if not info.parts_of_speech_filter
                    or LanguageTransformer.conditionsMatch(deinflection.conditions, definition_conditions) then
                table.insert(deinflection.database_entries, entry)
            end
        end
    end
end

--- Equivalent of DictionaryDatabase.findTermsBulk with exact matching:
-- rows matching any term on either the expression or the reading, ordered by
-- (term index, expression before reading, dictionary, row id) and with each
-- row reported only once.
function Translator:_findTermsBulk(terms)
    local candidates = {}
    for dict_order, dict in ipairs(self.dictionaries) do
        for _, row in ipairs(dict:findTermsBulk(terms)) do
            table.insert(candidates, { row = row, dict = dict, dict_order = dict_order })
        end
    end
    table.sort(candidates, function(a, b)
        if a.row.item_index ~= b.row.item_index then return a.row.item_index < b.row.item_index end
        if a.row.index_index ~= b.row.index_index then return a.row.index_index < b.row.index_index end
        if a.dict_order ~= b.dict_order then return a.dict_order < b.dict_order end
        return a.row.rowid < b.row.rowid
    end)
    local visited = {}
    local results = {}
    for _, c in ipairs(candidates) do
        local row = c.row
        -- Unique and ordered like Yomitan's auto-increment ids, which follow
        -- dictionary import order.
        local id = c.dict_order * 4294967296 + row.rowid
        if not visited[id] then
            visited[id] = true
            local definitions = row.definitions
            if definitions == nil then
                definitions = self.json_decode(row.glossary)
            end
            table.insert(results, {
                index = row.item_index,
                match_type = "exact",
                match_source = row.index_index == 0 and "term" or "reading",
                term = row.expression,
                reading = row.reading,
                definition_tags = splitField(row.definition_tags),
                term_tags = splitField(row.term_tags),
                rules = splitField(row.rules),
                definitions = definitions,
                score = row.score or 0,
                dictionary = c.dict.title,
                id = id,
                sequence = row.sequence or -1,
            })
        end
    end
    return results
end

local function isDeinflectionDefinition(definition)
    -- Glossary items are strings or objects with a "type" key; deinflection
    -- items are [uninflected, [rules...]] arrays.
    return type(definition) == "table" and definition.type == nil and definition[1] ~= nil
end

function Translator:_getDictionaryDeinflections(deinflections)
    local dictionary_deinflections = {}
    for _, deinflection in ipairs(deinflections) do
        for _, entry in ipairs(deinflection.database_entries) do
            local info = self.dictionary_info[entry.dictionary]
            if info.use_deinflections then
                for _, definition in ipairs(entry.definitions) do
                    if isDeinflectionDefinition(definition) then
                        local form_of, inflection_rules = definition[1], definition[2] or {}
                        if type(form_of) == "string" and form_of ~= "" then
                            local chains = {}
                            for i, alg in ipairs(deinflection.inflection_rule_chain_candidates) do
                                local rules = arrayCopy(alg.inflection_rules)
                                for _, r in ipairs(inflection_rules) do table.insert(rules, r) end
                                chains[i] = {
                                    source = #alg.inflection_rules == 0 and "dictionary" or "both",
                                    inflection_rules = rules,
                                }
                            end
                            table.insert(dictionary_deinflections, createDeinflection(
                                deinflection.original_text, deinflection.transformed_text, form_of, 0,
                                deinflection.text_processor_rule_chain_candidates, chains))
                        end
                    end
                end
            end
        end
    end
    self:_addEntriesToDeinflections(dictionary_deinflections)
    return dictionary_deinflections
end

function Translator:_getDeinflections(text, options)
    local deinflections
    if options.deinflect == false then
        deinflections = { createDeinflection(text, text, text, 0, {}, {}) }
    else
        deinflections = self:_getAlgorithmDeinflections(text)
    end
    if #deinflections == 0 then return {} end

    self:_addEntriesToDeinflections(deinflections)
    for _, d in ipairs(self:_getDictionaryDeinflections(deinflections)) do
        table.insert(deinflections, d)
    end

    local filtered = {}
    for _, deinflection in ipairs(deinflections) do
        local entries = {}
        for _, entry in ipairs(deinflection.database_entries) do
            if not entry._definitions_filtered then
                local defs = {}
                for _, definition in ipairs(entry.definitions) do
                    if not isDeinflectionDefinition(definition) then
                        table.insert(defs, definition)
                    end
                end
                entry.definitions = defs
                entry._definitions_filtered = true
            end
            if #entry.definitions > 0 then
                table.insert(entries, entry)
            end
        end
        deinflection.database_entries = entries
        if #entries > 0 then
            table.insert(filtered, deinflection)
        end
    end
    return filtered
end

-- Tag aggregation (TranslatorTagAggregator)

local TagAggregator = {}
TagAggregator.__index = TagAggregator

function TagAggregator.new()
    return setmetatable({ map = {}, order = {} }, TagAggregator)
end

function TagAggregator:_getOrCreateTagGroups(tags)
    local groups = self.map[tags]
    if not groups then
        groups = {}
        self.map[tags] = groups
        table.insert(self.order, tags)
    end
    return groups
end

local function getOrCreateTagGroup(tag_groups, dictionary)
    for _, g in ipairs(tag_groups) do
        if g.dictionary == dictionary then return g end
    end
    local g = { dictionary = dictionary, tag_names = {} }
    table.insert(tag_groups, g)
    return g
end

function TagAggregator:addTags(tags, dictionary, tag_names)
    if #tag_names == 0 then return end
    local group = getOrCreateTagGroup(self:_getOrCreateTagGroups(tags), dictionary)
    addUniqueSimple(group.tag_names, tag_names)
end

function TagAggregator:mergeTags(tags, new_tags)
    local new_groups = self.map[new_tags]
    if not new_groups then return end
    local groups = self:_getOrCreateTagGroups(tags)
    for _, g in ipairs(new_groups) do
        addUniqueSimple(getOrCreateTagGroup(groups, g.dictionary).tag_names, g.tag_names)
    end
end

function TagAggregator:getTagExpansionTargets()
    local out = {}
    for _, tags in ipairs(self.order) do
        table.insert(out, { tags = tags, tag_groups = self.map[tags] })
    end
    return out
end

local function createTag(database_tag, name, dictionary)
    local category, notes, order, score
    if database_tag then
        category, notes, order, score = database_tag.category, database_tag.notes, database_tag.order, database_tag.score
    end
    return {
        name = name,
        category = (type(category) == "string" and #category > 0) and category or "default",
        order = type(order) == "number" and order or 0,
        score = type(score) == "number" and score or 0,
        content = (type(notes) == "string" and #notes > 0) and { notes } or {},
        dictionaries = { dictionary },
        redundant = false,
    }
end

function Translator:_expandTagGroups(targets)
    local all_items = {}
    local target_map = {}
    for _, target in ipairs(targets) do
        for _, group in ipairs(target.tag_groups) do
            local dictionary_items = target_map[group.dictionary]
            if not dictionary_items then
                dictionary_items = {}
                target_map[group.dictionary] = dictionary_items
            end
            for _, tag_name in ipairs(group.tag_names) do
                local item = dictionary_items[tag_name]
                if not item then
                    item = { query = getNameBase(tag_name), dictionary = group.dictionary, tag_name = tag_name, targets = {} }
                    dictionary_items[tag_name] = item
                    table.insert(all_items, item)
                end
                table.insert(item.targets, target.tags)
            end
        end
    end

    for _, item in ipairs(all_items) do
        local cache = self.tag_cache[item.dictionary]
        if not cache then
            cache = {}
            self.tag_cache[item.dictionary] = cache
        end
        local database_tag = cache[item.query]
        if database_tag == nil then
            local info = self.dictionary_info[item.dictionary]
            database_tag = info and info.dictionary:findTagMeta(item.query) or false
            cache[item.query] = database_tag
        end
        item.database_tag = database_tag or nil
    end

    for _, item in ipairs(all_items) do
        for _, tags in ipairs(item.targets) do
            table.insert(tags, createTag(item.database_tag, item.tag_name, item.dictionary))
        end
    end
end

local function mergeSimilarTags(tags)
    local i = 1
    while i <= #tags do
        local tag1 = tags[i]
        local j = i + 1
        while j <= #tags do
            local tag2 = tags[j]
            if tag2.name == tag1.name and tag2.category == tag1.category then
                tag1.order = math.min(tag1.order, tag2.order)
                tag1.score = math.max(tag1.score, tag2.score)
                for _, d in ipairs(tag2.dictionaries) do table.insert(tag1.dictionaries, d) end
                addUniqueSimple(tag1.content, tag2.content)
                table.remove(tags, j)
            else
                j = j + 1
            end
        end
        i = i + 1
    end
end

local function compareTags(v1, v2)
    local i = v1.order - v2.order
    if i ~= 0 then return i end
    return compareStrings(v1.name, v2.name)
end

function Translator:_expandTagGroupsAndGroup(targets)
    self:_expandTagGroups(targets)
    for _, target in ipairs(targets) do
        local tags = target.tags
        if #tags > 1 then
            mergeSimilarTags(tags)
            stableSort(tags, compareTags)
        end
    end
end

local function flagRedundantDefinitionTags(definitions)
    if #definitions == 0 then return end
    local last_dictionary = nil
    local last_part_of_speech = ""
    for _, definition in ipairs(definitions) do
        local names = {}
        for _, tag in ipairs(definition.tags) do
            if tag.category == "partOfSpeech" then table.insert(names, tag.name) end
        end
        table.sort(names)
        local part_of_speech = table.concat(names, "\0")
        if last_dictionary ~= definition.dictionary then
            last_dictionary = definition.dictionary
            last_part_of_speech = ""
        end
        if last_part_of_speech == part_of_speech then
            for _, tag in ipairs(definition.tags) do
                if tag.category == "partOfSpeech" then tag.redundant = true end
            end
        else
            last_part_of_speech = part_of_speech
        end
    end
end

-- Dictionary entries

local function createTermHeadword(index, term, reading, sources, tags, word_classes)
    return { index = index, headword_index = index, term = term, reading = reading, sources = sources, tags = tags, word_classes = word_classes }
end

local function createTermDefinition(index, headword_indices, dictionary, dictionary_index, dictionary_alias, id, score, sequences, is_primary, tags, entries)
    return {
        index = index, headword_indices = headword_indices, dictionary = dictionary,
        dictionary_index = dictionary_index, dictionary_alias = dictionary_alias, id = id,
        score = score, frequency_order = 0, sequences = sequences, is_primary = is_primary,
        tags = tags, entries = entries,
    }
end

local function createTermDictionaryEntry(is_primary, text_processor_chains, inflection_chains, score, dictionary_index, dictionary_alias,
                                         source_term_exact_match_count, max_original_text_length, headwords, definitions)
    return {
        type = "term", is_primary = is_primary,
        text_processor_rule_chain_candidates = text_processor_chains,
        inflection_rule_chain_candidates = inflection_chains,
        score = score, frequency_order = 0, dictionary_index = dictionary_index, dictionary_alias = dictionary_alias,
        source_term_exact_match_count = source_term_exact_match_count, match_primary_reading = false,
        max_original_text_length = max_original_text_length,
        headwords = headwords, definitions = definitions,
    }
end

function Translator:_createTermDictionaryEntryFromDatabaseEntry(entry, original_text, transformed_text, deinflected_text,
                                                                text_processor_chains, inflection_chains, is_primary, tag_aggregator)
    local reading = #entry.reading > 0 and entry.reading or entry.term
    local info = self.dictionary_info[entry.dictionary]
    local source_term_exact_match_count = (is_primary and deinflected_text == entry.term) and 1 or 0
    local source = {
        original_text = original_text, transformed_text = transformed_text, deinflected_text = deinflected_text,
        match_type = entry.match_type, match_source = entry.match_source, is_primary = is_primary,
    }
    local headword_tags, definition_tags = {}, {}
    tag_aggregator:addTags(headword_tags, entry.dictionary, entry.term_tags)
    tag_aggregator:addTags(definition_tags, entry.dictionary, entry.definition_tags)
    local sequence = entry.sequence >= 0 and entry.sequence or -1
    return createTermDictionaryEntry(
        is_primary, text_processor_chains, inflection_chains, entry.score, info.index, info.alias,
        source_term_exact_match_count, ulen(original_text),
        { createTermHeadword(0, entry.term, reading, { source }, headword_tags, entry.rules) },
        { createTermDefinition(0, { 0 }, entry.dictionary, info.index, info.alias, entry.id, entry.score, { sequence },
                               is_primary, definition_tags, entry.definitions) })
end

local function findExistingEntry(dictionary_entries, id)
    for index, entry in ipairs(dictionary_entries) do
        for _, definition in ipairs(entry.definitions) do
            if definition.id == id then
                return entry, index
            end
        end
    end
end

local function mergeInflectionRuleChains(existing_entry, chains)
    local existing_chains = existing_entry.inflection_rule_chain_candidates
    for _, chain in ipairs(chains) do
        local duplicate
        for _, existing in ipairs(existing_chains) do
            if arraysEqualIgnoreOrder(existing.inflection_rules, chain.inflection_rules) then
                duplicate = existing
                break
            end
        end
        if not duplicate then
            table.insert(existing_chains, { source = chain.source, inflection_rules = chain.inflection_rules })
        elseif duplicate.source ~= chain.source then
            duplicate.source = "both"
        end
    end
end

local function mergeTextProcessorRuleChains(existing_entry, chains)
    local existing_chains = existing_entry.text_processor_rule_chain_candidates
    for _, chain in ipairs(chains) do
        local duplicate = false
        for _, existing in ipairs(existing_chains) do
            if arraysEqualIgnoreOrder(existing, chain) then
                duplicate = true
                break
            end
        end
        if not duplicate then
            table.insert(existing_chains, chain)
        end
    end
end

function Translator:_getDictionaryEntries(deinflections, tag_aggregator)
    local original_text_length = 0
    local dictionary_entries = {}
    local ids = {}
    for _, d in ipairs(deinflections) do
        if #d.database_entries > 0 then
            original_text_length = math.max(original_text_length, ulen(d.original_text))
            for _, entry in ipairs(d.database_entries) do
                local id = entry.id
                if ids[id] then
                    local existing_entry, existing_index = findExistingEntry(dictionary_entries, id)
                    if existing_entry then
                        local existing_transformed = existing_entry.headwords[1].sources[1].transformed_text
                        local existing_len = ulen(existing_transformed)
                        local transformed_len = ulen(d.transformed_text)
                        if transformed_len > existing_len then
                            if d.original_text ~= existing_transformed then
                                dictionary_entries[existing_index] = self:_createTermDictionaryEntryFromDatabaseEntry(
                                    entry, d.original_text, d.transformed_text, d.deinflected_text,
                                    d.text_processor_rule_chain_candidates, d.inflection_rule_chain_candidates, true, tag_aggregator)
                            end
                        elseif transformed_len == existing_len then
                            mergeInflectionRuleChains(existing_entry, d.inflection_rule_chain_candidates)
                            mergeTextProcessorRuleChains(existing_entry, d.text_processor_rule_chain_candidates)
                        end
                    end
                else
                    table.insert(dictionary_entries, self:_createTermDictionaryEntryFromDatabaseEntry(
                        entry, d.original_text, d.transformed_text, d.deinflected_text,
                        d.text_processor_rule_chain_candidates, d.inflection_rule_chain_candidates, true, tag_aggregator))
                    ids[id] = true
                end
            end
        end
    end
    return dictionary_entries, original_text_length
end

-- Grouping

local function addUniqueSources(sources, new_sources)
    if #new_sources == 0 then return end
    if #sources == 0 then
        for _, s in ipairs(new_sources) do table.insert(sources, s) end
        return
    end
    for _, new_source in ipairs(new_sources) do
        local has = false
        for _, source in ipairs(sources) do
            if source.deinflected_text == new_source.deinflected_text
                    and source.transformed_text == new_source.transformed_text
                    and source.original_text == new_source.original_text
                    and source.match_type == new_source.match_type
                    and source.match_source == new_source.match_source then
                if new_source.is_primary then source.is_primary = true end
                has = true
                break
            end
        end
        if not has then
            table.insert(sources, new_source)
        end
    end
end

local function addTermHeadwords(headwords_map, headwords, tag_aggregator)
    local index_map = {}
    for _, hw in ipairs(headwords) do
        local key = hw.term .. "\0" .. hw.reading
        local headword = headwords_map.values[key]
        if not headword then
            headword = createTermHeadword(#headwords_map.keys, hw.term, hw.reading, {}, {}, {})
            orderedSet(headwords_map, key, headword)
        end
        addUniqueSources(headword.sources, hw.sources)
        addUniqueSimple(headword.word_classes, hw.word_classes)
        tag_aggregator:mergeTags(headword.tags, hw.tags)
        table.insert(index_map, headword.index)
    end
    return index_map
end

local function sortHeadwords(headwords, headword_dictionary_indices, definitions)
    local function hasPrimary(h)
        for _, s in ipairs(h.sources) do
            if s.is_primary then return true end
        end
        return false
    end
    stableSort(headwords, function(a, b)
        local ap, bp = hasPrimary(a), hasPrimary(b)
        if ap ~= bp then return ap and -1 or 1 end
        local ai = headword_dictionary_indices[a.index] or math.huge
        local bi = headword_dictionary_indices[b.index] or math.huge
        if ai == bi then return 0 end
        return ai < bi and -1 or 1
    end)
    local remap = {}
    for i, h in ipairs(headwords) do
        remap[h.index] = i - 1
        h.index = i - 1
        h.headword_index = i - 1
    end
    for _, definition in ipairs(definitions) do
        for i, old in ipairs(definition.headword_indices) do
            if remap[old] then definition.headword_indices[i] = remap[old] end
        end
    end
end

local function createGroupedDictionaryEntry(dictionary_entries, tag_aggregator)
    local headwords_map = newOrderedMap()
    local headword_dictionary_indices = {}
    local definition_entries = {}
    for _, dictionary_entry in ipairs(dictionary_entries) do
        local index_map = addTermHeadwords(headwords_map, dictionary_entry.headwords, tag_aggregator)
        for _, hw_index in ipairs(index_map) do
            local existing = headword_dictionary_indices[hw_index]
            if existing == nil or dictionary_entry.dictionary_index < existing then
                headword_dictionary_indices[hw_index] = dictionary_entry.dictionary_index
            end
        end
        table.insert(definition_entries, { dictionary_entry = dictionary_entry, headword_index_map = index_map })
    end

    local score = -math.huge
    local dictionary_index = math.huge
    local max_original_text_length = 0
    local is_primary = false
    local definitions = {}
    local inflections, text_processes
    for _, de in ipairs(definition_entries) do
        local entry = de.dictionary_entry
        score = math.max(score, entry.score)
        dictionary_index = math.min(dictionary_index, entry.dictionary_index)
        if entry.is_primary then
            is_primary = true
            max_original_text_length = math.max(max_original_text_length, entry.max_original_text_length)
            if inflections == nil or #entry.inflection_rule_chain_candidates < #inflections then
                inflections = entry.inflection_rule_chain_candidates
            end
            if text_processes == nil or #entry.text_processor_rule_chain_candidates < #text_processes then
                text_processes = entry.text_processor_rule_chain_candidates
            end
        end
        -- _addTermDefinitionsFast
        for _, def in ipairs(entry.definitions) do
            local indices = {}
            for i, hw_index in ipairs(def.headword_indices) do
                indices[i] = de.headword_index_map[hw_index + 1]
            end
            table.insert(definitions, createTermDefinition(#definitions, indices, def.dictionary, def.dictionary_index,
                def.dictionary_alias, def.id, def.score, def.sequences, def.is_primary, def.tags, def.entries))
        end
    end

    local headwords = {}
    for _, key in ipairs(headwords_map.keys) do
        table.insert(headwords, headwords_map.values[key])
    end
    sortHeadwords(headwords, headword_dictionary_indices, definitions)

    local source_term_exact_match_count = 0
    for _, hw in ipairs(headwords) do
        for _, source in ipairs(hw.sources) do
            if source.is_primary and source.match_source == "term" then
                source_term_exact_match_count = source_term_exact_match_count + 1
                break
            end
        end
    end

    return createTermDictionaryEntry(is_primary, text_processes or {}, inflections or {}, score, dictionary_index, "",
        source_term_exact_match_count, max_original_text_length, headwords, definitions)
end

local function chainsKey(chains)
    local parts = {}
    for i, c in ipairs(chains) do
        parts[i] = c.source .. "\1" .. table.concat(c.inflection_rules, "\1")
    end
    return table.concat(parts, "\2")
end

local function groupDictionaryEntries(dictionary_entries, tag_aggregator, include_reading)
    local groups = newOrderedMap()
    for _, entry in ipairs(dictionary_entries) do
        local hw = entry.headwords[1]
        local key = hw.term .. "\0" .. (include_reading and hw.reading or "") .. "\0" .. chainsKey(entry.inflection_rule_chain_candidates)
        local list = groups.values[key]
        if not list then
            list = {}
            orderedSet(groups, key, list)
        end
        table.insert(list, entry)
    end
    local out = {}
    for _, key in ipairs(groups.keys) do
        table.insert(out, createGroupedDictionaryEntry(groups.values[key], tag_aggregator))
    end
    return out
end

-- Sorting

local function shortestLength(candidates, field)
    if #candidates == 0 then return 0 end
    local length = math.huge
    for _, c in ipairs(candidates) do
        local list = field and c[field] or c
        length = math.min(length, #list)
    end
    return length
end

local function compareEntries(v1, v2)
    local i = (v2.match_primary_reading and 1 or 0) - (v1.match_primary_reading and 1 or 0)
    if i ~= 0 then return i end
    i = v2.max_original_text_length - v1.max_original_text_length
    if i ~= 0 then return i end
    i = shortestLength(v1.text_processor_rule_chain_candidates) - shortestLength(v2.text_processor_rule_chain_candidates)
    if i ~= 0 then return i end
    i = shortestLength(v1.inflection_rule_chain_candidates, "inflection_rules") - shortestLength(v2.inflection_rule_chain_candidates, "inflection_rules")
    if i ~= 0 then return i end
    i = v2.source_term_exact_match_count - v1.source_term_exact_match_count
    if i ~= 0 then return i end
    i = v1.frequency_order - v2.frequency_order
    if i ~= 0 then return i end
    i = v1.dictionary_index - v2.dictionary_index
    if i ~= 0 then return i end
    i = v2.score - v1.score
    if i ~= 0 then return i end
    local h1, h2 = v1.headwords, v2.headwords
    for j = 1, math.min(#h1, #h2) do
        local t1, t2 = h1[j].term, h2[j].term
        i = ulen(t2) - ulen(t1)
        if i ~= 0 then return i end
        i = compareStrings(t1, t2)
        if i ~= 0 then return i end
    end
    return #v2.definitions - #v1.definitions
end

local function compareDefinitions(v1, v2)
    local i = v1.frequency_order - v2.frequency_order
    if i ~= 0 then return i end
    i = v1.dictionary_index - v2.dictionary_index
    if i ~= 0 then return i end
    i = v2.score - v1.score
    if i ~= 0 then return i end
    local h1, h2 = v1.headword_indices, v2.headword_indices
    i = #h2 - #h1
    if i ~= 0 then return i end
    for j = 1, #h1 do
        i = h1[j] - h2[j]
        if i ~= 0 then return i end
    end
    return v1.index - v2.index
end

--- Find terms for the text starting at the scanned position.
-- @tparam string text up to scan-length characters of document text
-- @tparam table options {mode = "group"|"term"|"split", deinflect = bool, remove_non_japanese = bool}
-- @treturn table {entries = {...}, original_text_length = number (characters)}
function Translator:findTerms(text, options)
    options = options or {}
    local mode = options.mode or "group"
    if options.remove_non_japanese then
        text = Japanese.getCJKOnlyText(text)
    end
    if text == "" or #self.dictionaries == 0 then
        return { entries = {}, original_text_length = 0 }
    end

    local tag_aggregator = TagAggregator.new()
    local deinflections = self:_getDeinflections(text, options)
    local dictionary_entries, original_text_length = self:_getDictionaryEntries(deinflections, tag_aggregator)

    if mode == "group" then
        dictionary_entries = groupDictionaryEntries(dictionary_entries, tag_aggregator, true)
    elseif mode == "term" then
        dictionary_entries = groupDictionaryEntries(dictionary_entries, tag_aggregator, false)
    end

    self:_expandTagGroupsAndGroup(tag_aggregator:getTagExpansionTargets())

    if #dictionary_entries > 1 then
        stableSort(dictionary_entries, compareEntries)
    end
    for _, entry in ipairs(dictionary_entries) do
        flagRedundantDefinitionTags(entry.definitions)
        if #entry.definitions > 1 then
            stableSort(entry.definitions, compareDefinitions)
        end
        local expanded = {}
        for i, chain in ipairs(entry.inflection_rule_chain_candidates) do
            expanded[i] = {
                source = chain.source,
                inflection_rules = self.transformer:getUserFacingInflectionRules(chain.inflection_rules),
            }
        end
        entry.inflection_rule_chain_candidates = expanded
    end

    return { entries = dictionary_entries, original_text_length = original_text_length }
end

return Translator
