--[[--
Port of Yomitan's LanguageTransformer (ext/js/language/language-transformer.js).

Deinflects text with a breadth-first expansion over suffix/prefix/whole-word
rules, tracking grammatical conditions as bit flags so that only valid rule
chains are produced. The produced results (and their order) match Yomitan.

The deinflection itself runs in crengine (JpDeinflector, in jpwords.cpp),
which also uses it to keep words together at column breaks. This module is a
thin wrapper with the original API. The engine holds a single rule set:
addDescriptor() replaces it, so all instances share the last descriptor.

@module yomitan.language_transformer
]]

local cre = require("libs/libkoreader-cre")
local bit = require("bit")
local band = bit.band

local LanguageTransformer = {}
LanguageTransformer.__index = LanguageTransformer

function LanguageTransformer.new()
    local o = setmetatable({}, LanguageTransformer)
    o:clear()
    return o
end

function LanguageTransformer:clear()
    self._transforms_by_id = {}
end

--- Mirrors LanguageTransformer.conditionsMatch: a 0 (unconstrained) current
-- condition matches anything, otherwise at least one flag must be shared.
function LanguageTransformer.conditionsMatch(current_conditions, next_conditions)
    return current_conditions == 0 or band(current_conditions, next_conditions) ~= 0
end

--- Add a language transform descriptor (see yomitan/data/transforms_ja.lua).
function LanguageTransformer:addDescriptor(descriptor)
    cre.jpSetDeinflectRules(descriptor)
    for _, transform in ipairs(descriptor.transforms) do
        self._transforms_by_id[transform.id] = {
            name = transform.name,
            name_ja = transform.name_ja,
            description = transform.description,
        }
    end
end

function LanguageTransformer:getConditionFlagsFromPartsOfSpeech(parts_of_speech)
    return cre.jpConditionFlags(parts_of_speech)
end

function LanguageTransformer:getConditionFlagsFromConditionTypes(condition_types)
    return cre.jpConditionFlags(condition_types, true)
end

function LanguageTransformer:getConditionFlagsFromConditionType(condition_type)
    return cre.jpConditionFlags({condition_type}, true)
end

--- Deinflect text.
-- @treturn {{text=string, conditions=number, trace={{transform=string, rule_index=number, text=string},...}},...}
-- The trace lists the most recently applied transform first, as in Yomitan.
function LanguageTransformer:transform(source_text)
    return cre.jpDeinflect(source_text)
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
