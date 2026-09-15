--!strict

local Schema = require(script.Parent.Schema)

export type Step = (any) -> any

-- Indexed by source version: steps[1] must produce SchemaVersion 2.
-- Version 1 shipped with an empty inventory placeholder. Its non-empty values have no
-- reliable stack/discrete interpretation, so they must not be guessed or discarded.
local function migrateV1ToV2(data: any): any
	if type(data.Inventory) ~= "table" or next(data.Inventory) ~= nil then
		error("Cannot safely migrate a non-empty v1 inventory")
	end
	data.Inventory = { Stacks = {}, Items = {} }
	data.SchemaVersion = 2
	return data
end

-- The exact skill IDs that existed when schema v3 was created. This must stay frozen to that
-- historical moment -- never derived from the live SkillIds module or Schema.New() -- so this
-- migration's output cannot silently change when later skills are added. A future skill's
-- respec history is the responsibility of its own future migration, not this one.
local SCHEMA_V3_SKILL_IDS = table.freeze({ "skill_melee", "skill_defense", "skill_mining", "skill_smithing" })

-- Version 2 had no per-skill Mastery respec history. Every existing skill has never respecced,
-- so its one-time free respec is still unused (false) for every save migrating through here.
local function migrateV2ToV3(data: any): any
	local masteryRespecs: { [string]: boolean } = {}
	for _, id in SCHEMA_V3_SKILL_IDS do
		masteryRespecs[id] = false
	end
	data.MasteryRespecs = masteryRespecs
	data.SchemaVersion = 3
	return data
end

-- Version 3 had no offline-training focus/claim state. Every migrating save starts with no
-- selected focus and no prior claim -- this never fabricates historical offline progress.
local function migrateV3ToV4(data: any): any
	data.OfflineTraining = { FocusSkillId = "", ClaimedThroughAt = 0 }
	data.SchemaVersion = 4
	return data
end

local steps: { [number]: Step } = {
	[1] = migrateV1ToV2,
	[2] = migrateV2ToV3,
	[3] = migrateV3ToV4,
}
table.freeze(steps)

local Migrations = {}

function Migrations.Run(raw: any, targetVersion: number, migrations: { [number]: Step }): (any?, string?)
	if not Schema.IsSerializable(raw) or type(raw) ~= "table" then
		return nil, "InvalidData"
	end
	local version = raw.SchemaVersion
	if type(version) ~= "number" or version < 1 or version % 1 ~= 0 then
		return nil, "InvalidVersion"
	end
	if version > targetVersion then
		return nil, "FutureVersion"
	end
	local data = Schema.Copy(raw)
	while version < targetVersion do
		local migrate = migrations[version]
		if not migrate then
			return nil, "MissingMigration"
		end
		-- Migrations run inside UpdateAsync: deterministic and non-yielding.
		local ok, result = pcall(migrate, data)
		if not ok or not Schema.IsSerializable(result) or type(result) ~= "table" or result.SchemaVersion ~= version + 1 then
			return nil, "InvalidMigration"
		end
		data = result
		version += 1
	end
	return data, nil
end

function Migrations.ToCurrent(raw: any): (Schema.Data?, string?)
	local data, reason = Migrations.Run(raw, Schema.Version, steps)
	if not data then
		return nil, reason
	end
	if not Schema.Validate(data) then
		return nil, "InvalidData"
	end
	return data, nil
end

return table.freeze(Migrations)
