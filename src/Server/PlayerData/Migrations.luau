--!strict

local Schema = require(script.Parent.Schema)

export type Step = (any) -> any

-- Indexed by the source version: steps[1] must produce SchemaVersion 2.
-- Version 1 is the first shipped schema; there is no legacy/unversioned format.
local steps: { [number]: Step } = {}
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
