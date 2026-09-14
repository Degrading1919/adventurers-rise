--!strict

local SkillIds = require(game:GetService("ReplicatedStorage").Shared.SkillIds)

export type Value = boolean | number | string | { [string]: Value }
export type Record = { [string]: Value }
export type DiscreteItem = { DefinitionId: string }
export type Inventory = {
	Stacks: { [string]: number },
	Items: { [string]: DiscreteItem },
}
export type Data = {
	SchemaVersion: number,
	Gold: number,
	SkillXP: { [string]: number },
	Ascension: { RankId: string, Flags: { [string]: boolean } },
	Inventory: Inventory,
	Equipment: { [string]: string },
	Plot: { Stations: { [string]: Record } },
	ProgressionFlags: { [string]: boolean },
	MasterySelections: { [string]: { [string]: boolean } },
	LastSessionAt: number,
}

local Schema = { Version = 2, MaxDepth = 16 }

function Schema.New(): Data
	local xp: { [string]: number } = {}
	local mastery: { [string]: { [string]: boolean } } = {}
	for _, id in SkillIds do
		xp[id] = 0
		mastery[id] = {}
	end
	return {
		SchemaVersion = Schema.Version,
		Gold = 0,
		SkillXP = xp,
		Ascension = { RankId = "ascension_adventurer", Flags = {} },
		Inventory = { Stacks = {}, Items = {} },
		Equipment = {},
		Plot = { Stations = {} },
		ProgressionFlags = {},
		MasterySelections = mastery,
		LastSessionAt = 0,
	}
end

-- Only string-keyed dictionaries and finite JSON primitives enter a save.
function Schema.IsSerializable(value: any, maxDepth: number?): boolean
	local ancestors: { [any]: boolean } = {}
	local function visit(item: any, depth: number): boolean
		if type(item) == "string" then
			return utf8.len(item) ~= nil
		elseif type(item) == "number" then
			return item == item and math.abs(item) < math.huge
		elseif type(item) == "boolean" then
			return true
		elseif type(item) ~= "table" or getmetatable(item) ~= nil or ancestors[item] or depth > (maxDepth or Schema.MaxDepth) then
			return false
		end
		ancestors[item] = true
		for key, child in item do
			if type(key) ~= "string" or key == "" or utf8.len(key) == nil or not visit(child, depth + 1) then
				return false
			end
		end
		ancestors[item] = nil
		return true
	end
	return visit(value, 0)
end

-- Call only on validated serializable data; copies never share mutable tables.
function Schema.Copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, child in value do
		copy[key] = Schema.Copy(child)
	end
	return copy
end

local function whole(value: any): boolean
	return type(value) == "number" and value >= 0 and value <= 9007199254740991 and value % 1 == 0
end

local function positiveWhole(value: any): boolean
	return whole(value) and value > 0
end

local function dictionary(value: any, check: (any) -> boolean): boolean
	if type(value) ~= "table" then
		return false
	end
	for _, child in value do
		if not check(child) then
			return false
		end
	end
	return true
end

local function sameKeys(value: any, template: any): boolean
	if type(value) ~= "table" then
		return false
	end
	for key in template do
		if value[key] == nil then
			return false
		end
	end
	for key in value do
		if template[key] == nil then
			return false
		end
	end
	return true
end

function Schema.Validate(value: any): boolean
	if not Schema.IsSerializable(value) then
		return false
	end
	local defaults = Schema.New()
	local function flags(item: any): boolean
		return dictionary(item, function(flag) return type(flag) == "boolean" end)
	end
	local function discreteItem(item: any): boolean
		return sameKeys(item, { DefinitionId = "" }) and type(item.DefinitionId) == "string" and item.DefinitionId ~= ""
	end
	return sameKeys(value, defaults)
		and value.SchemaVersion == Schema.Version
		and whole(value.Gold)
		and sameKeys(value.SkillXP, defaults.SkillXP)
		and dictionary(value.SkillXP, function(xp) return type(xp) == "number" and xp >= 0 end)
		and sameKeys(value.Ascension, defaults.Ascension)
		and type(value.Ascension.RankId) == "string" and value.Ascension.RankId ~= ""
		and flags(value.Ascension.Flags)
		and sameKeys(value.Inventory, defaults.Inventory)
		and dictionary(value.Inventory.Stacks, positiveWhole)
		and dictionary(value.Inventory.Items, discreteItem)
		and dictionary(value.Equipment, function(id) return type(id) == "string" and id ~= "" end)
		and sameKeys(value.Plot, defaults.Plot)
		and dictionary(value.Plot.Stations, function(state) return type(state) == "table" end)
		and flags(value.ProgressionFlags)
		and sameKeys(value.MasterySelections, defaults.MasterySelections)
		and dictionary(value.MasterySelections, flags)
		and whole(value.LastSessionAt)
end

return table.freeze(Schema)
