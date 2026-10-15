--[[--
Port of Yomitan's LanguageTransformer (ext/js/language/language-transformer.js).

Deinflects text with a breadth-first expansion over suffix/prefix/whole-word
rules, tracking grammatical conditions as bit flags so that only valid rule
chains are produced. The produced results (and their order) match Yomitan.

@module yomitan.language_transformer
]]

local UString = require("yomitan/ustring")
local bit = require("bit")
local band, bor, lshift = bit.band, bit.bor, bit.lshift

local LanguageTransformer = {}
LanguageTransformer.__index = LanguageTransformer

function LanguageTransformer.new()
    local o = setmetatable({}, LanguageTransformer)
    o:clear()
    return o
end

function LanguageTransformer:clear()
    self._next_flag_index = 0
    self._transforms = {}
    self._transforms_by_id = {}
    self._condition_type_to_flags = {}
    self._part_of_speech_to_flags = {}
end

--- Mirrors LanguageTransformer.conditionsMatch: a 0 (unconstrained) current
-- condition matches anything, otherwise at least one flag must be shared.
function LanguageTransformer.conditionsMatch(current_conditions, next_conditions)
    return current_conditions == 0 or band(current_conditions, next_conditions) ~= 0
end

local function getConditionFlagsStrict(flags_map, condition_types)
    local flags = 0
    for _, condition_type in ipairs(condition_types) do
        local flags2 = flags_map[condition_type]
        if flags2 == nil then
            return nil
        end
        flags = bor(flags, flags2)
    end
    return flags
end

local function getConditionFlags(flags_map, condition_types)
    local flags = 0
    for _, condition_type in ipairs(condition_types) do
        flags = bor(flags, flags_map[condition_type] or 0)
    end
    return flags
end

function LanguageTransformer:_getConditionFlagsMap(conditions, next_flag_index)
    local flags_map = {}
    local targets = conditions
    while #targets > 0 do
        local next_targets = {}
        for _, condition in ipairs(targets) do
            local flags
            if condition.sub_conditions == nil then
                if next_flag_index >= 32 then
                    error("Maximum number of conditions was exceeded")
                end
                flags = lshift(1, next_flag_index)
                next_flag_index = next_flag_index + 1
            else
                flags = getConditionFlagsStrict(flags_map, condition.sub_conditions)
            end
            if flags == nil then
                table.insert(next_targets, condition)
            else
                flags_map[condition.id] = flags
            end
        end
        if #next_targets == #targets then
            error("Cycle in condition declarations")
        end
        targets = next_targets
    end
    return flags_map, next_flag_index
end

--- Add a language transform descriptor (see yomitan/data/transforms_ja.lua).
function LanguageTransformer:addDescriptor(descriptor)
    local flags_map, next_flag_index = self:_getConditionFlagsMap(descriptor.conditions, self._next_flag_index)

    local transforms = {}
    for _, transform in ipairs(descriptor.transforms) do
        local rules = {}
        -- Precomputed heuristic: the set of last characters a matching text
        -- can end with. This replaces Yomitan's per-transform RegExp test
        -- without changing which rules are tried, or in which order.
        local last_chars = {}
        local always = false
        for j, rule in ipairs(transform.rules) do
            local rule_type, inflected, deinflected, conditions_in, conditions_out = rule[1], rule[2], rule[3], rule[4], rule[5]
            local flags_in = getConditionFlagsStrict(flags_map, conditions_in)
            if flags_in == nil then
                error(string.format("Invalid conditionsIn for transform %s.rules[%d]", transform.id, j - 1))
            end
            local flags_out = getConditionFlagsStrict(flags_map, conditions_out)
            if flags_out == nil then
                error(string.format("Invalid conditionsOut for transform %s.rules[%d]", transform.id, j - 1))
            end
            rules[j] = {
                type = rule_type,
                inflected = inflected,
                deinflected = deinflected,
                conditions_in = flags_in,
                conditions_out = flags_out,
            }
            if rule_type == "prefix" or inflected == "" then
                always = true
            else
                local chars = UString.chars(inflected)
                last_chars[chars[#chars]] = true
            end
        end
        local t = {
            id = transform.id,
            name = transform.name,
            name_ja = transform.name_ja,
            description = transform.description,
            rules = rules,
            last_chars = last_chars,
            always = always,
        }
        table.insert(transforms, t)
    end

    self._next_flag_index = next_flag_index
    for _, t in ipairs(transforms) do
        table.insert(self._transforms, t)
        self._transforms_by_id[t.id] = t
    end

    for _, condition in ipairs(descriptor.conditions) do
        local flags = flags_map[condition.id]
        if flags ~= nil then
            self._condition_type_to_flags[condition.id] = flags
            if condition.is_dictionary_form then
                self._part_of_speech_to_flags[condition.id] = flags
            end
        end
    end
end

function LanguageTransformer:getConditionFlagsFromPartsOfSpeech(parts_of_speech)
    return getConditionFlags(self._part_of_speech_to_flags, parts_of_speech)
end

function LanguageTransformer:getConditionFlagsFromConditionTypes(condition_types)
    return getConditionFlags(self._condition_type_to_flags, condition_types)
end

function LanguageTransformer:getConditionFlagsFromConditionType(condition_type)
    return getConditionFlags(self._condition_type_to_flags, {condition_type})
end

local function ruleMatches(rule, text)
    local rule_type = rule.type
    if rule_type == "suffix" then
        return UString.endsWith(text, rule.inflected)
    elseif rule_type == "prefix" then
        return UString.startsWith(text, rule.inflected)
    else -- wholeWord
        return text == rule.inflected
    end
end

local function applyRule(rule, text)
    local rule_type = rule.type
    if rule_type == "suffix" then
        return text:sub(1, #text - #rule.inflected) .. rule.deinflected
    elseif rule_type == "prefix" then
        return rule.deinflected .. text:sub(#rule.inflected + 1)
    else -- wholeWord
        return rule.deinflected
    end
end

local function lastChar(text)
    -- Walk back over UTF-8 continuation bytes.
    local i = #text
    while i > 1 do
        local b = text:byte(i)
        if b < 0x80 or b >= 0xC0 then break end
        i = i - 1
    end
    return text:sub(i)
end

--- Deinflect text.
-- @treturn {{text=string, conditions=number, trace={{transform=string, rule_index=number, text=string},...}},...}
-- The trace lists the most recently applied transform first, as in Yomitan.
function LanguageTransformer:transform(source_text)
    local results = { { text = source_text, conditions = 0, trace = {} } }
    local i = 1
    while i <= #results do
        local current = results[i]
        local text, conditions, trace = current.text, current.conditions, current.trace
        local last = lastChar(text)
        for _, transform in ipairs(self._transforms) do
            if transform.always or transform.last_chars[last] then
                local id = transform.id
                for j, rule in ipairs(transform.rules) do
                    if LanguageTransformer.conditionsMatch(conditions, rule.conditions_in) and ruleMatches(rule, text) then
                        local is_cycle = false
                        for _, frame in ipairs(trace) do
                            if frame.transform == id and frame.rule_index == j and frame.text == text then
                                is_cycle = true
                                break
                            end
                        end
                        if not is_cycle then
                            local new_trace = { { transform = id, rule_index = j, text = text } }
                            for k = 1, #trace do
                                new_trace[k + 1] = trace[k]
                            end
                            table.insert(results, {
                                text = applyRule(rule, text),
                                conditions = rule.conditions_out,
                                trace = new_trace,
                            })
                        end
                    end
                end
            end
        end
        i = i + 1
    end
    return results
end

--- Map transform ids to {name=, description=} for display.
function LanguageTransformer:getUserFacingInflectionRules(inflection_rules)
    local out = {}
    for i, rule in ipairs(inflection_rules) do
        local t = self._transforms_by_id[rule]
        if t then
            out[i] = { name = t.name, name_ja = t.name_ja, description = t.description }
        else
            out[i] = { name = rule }
        end
    end
    return out
end

return LanguageTransformer
