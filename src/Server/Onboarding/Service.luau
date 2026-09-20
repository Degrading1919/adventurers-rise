--!strict

-- Authoritative onboarding evaluation for the shortened vertical slice. It derives the player's
-- current onboarding step from durable, monotonic facts (skill levels, Adept rank, and persisted
-- ProgressionFlags) and exposes a sanitized view for the read model. It also owns the trusted writes
-- that latch the one-time historical milestones which transient state cannot safely reconstruct.
--
-- Authority boundary: the client never marks a step complete, grants the onboarding Gold reward, or
-- sets a flag. It may only REQUEST to acknowledge the starter focus (a one-time UI confirmation), and
-- read the derived view. Every historical action milestone is written ONLY from the trusted server
-- path that proves the action actually happened -- never inferred from mere inventory presence (which
-- a purchase or an external grant could fabricate):
--   * NoteGoblinDefeated -- CombatRewards, on the hit that consumes an actual EnemyIds.Goblin death;
--   * NoteOreGathered    -- a successful Gathering settlement that awarded Iron Ore (not buying ore);
--   * NoteBarSmithed     -- a successful recipe_iron_bar craft at the Forge (not owning a bar).
-- Settle reconciles only the milestones that ARE safe to derive from authoritative state: the Gold
-- threshold, the upgraded-weapon acquisition (owning it, from either crafting or buying), and the
-- once-only post-training Gold reward, inside a single transaction.
-- Because every milestone is a durable flag (or a monotonic level/rank), a player who later spends
-- Gold, consumes ore/bars, or sells the sword never regresses to an already-completed step.

local Definitions = require(script.Parent.Definitions)

local ProgressionFlagIds = require(game:GetService("ReplicatedStorage").Shared.ProgressionFlagIds)
local SkillIds = require(game:GetService("ReplicatedStorage").Shared.SkillIds)
local EnemyIds = require(game:GetService("ReplicatedStorage").Shared.EnemyIds)

export type Skills = { read GetStateFromData: (any, string) -> (any?, string?) }
export type Economy = { read CreditGoldToData: (any, number) -> (number?, string?) }
export type PlayerData = {
	read GetSnapshot: (number) -> any?,
	read Update: (number, (any) -> ()) -> (boolean, string?),
}

local Flags = ProgressionFlagIds
local MAXIMUM_USER_ID = 9007199254740991

local Service = {}

local function validUserId(value: any): boolean
	return type(value) == "number" and value > 0 and value % 1 == 0 and value <= MAXIMUM_USER_ID
end

-- Construction-time self-check so a malformed onboarding definition fails loudly at boot.
local definitionsValid, definitionsReason = Definitions.Validate(Definitions.Ordered)
assert(definitionsValid, "Onboarding definitions invalid: " .. tostring(definitionsReason))

function Service.New(playerData: PlayerData, deps: { Skills: Skills, Economy: Economy })
	assert(type(playerData) == "table" and type(playerData.GetSnapshot) == "function" and type(playerData.Update) == "function", "Onboarding requires a PlayerData service")
	assert(type(deps) == "table" and type(deps.Skills) == "table" and type(deps.Skills.GetStateFromData) == "function", "Onboarding requires Skills.GetStateFromData")
	assert(type(deps.Economy) == "table" and type(deps.Economy.CreditGoldToData) == "function", "Onboarding requires Economy.CreditGoldToData")

	local skills = deps.Skills
	local economy = deps.Economy
	local service = {}

	-- ===== authoritative fact readers (operate on any data table: snapshot OR transactional) =====
	local function flagSet(data: any, flagId: string): boolean
		local flags = data.ProgressionFlags
		return type(flags) == "table" and flags[flagId] == true
	end

	local function skillLevel(data: any, skillId: string): number
		local state = skills.GetStateFromData(data, skillId)
		if type(state) == "table" and type(state.Level) == "number" then
			return state.Level
		end
		return 0
	end

	local function ownsDefinition(data: any, definitionId: string): boolean
		local inventory = data.Inventory
		if type(inventory) ~= "table" or type(inventory.Items) ~= "table" then
			return false
		end
		for _, item in inventory.Items do
			if type(item) == "table" and item.DefinitionId == definitionId then
				return true
			end
		end
		return false
	end

	local function rankId(data: any): string?
		local ascension = data.Ascension
		if type(ascension) == "table" and type(ascension.RankId) == "string" then
			return ascension.RankId
		end
		return nil
	end

	-- ===== step completion / progress (authoritative; never client-decided) =====
	local function stepComplete(step: any, data: any): boolean
		local check = step.Check
		if check.Kind == "Flag" then
			return flagSet(data, check.FlagId)
		elseif check.Kind == "SkillLevel" then
			return skillLevel(data, check.SkillId) >= check.Level
		elseif check.Kind == "Acquire" then
			return flagSet(data, check.FlagId) or ownsDefinition(data, check.DefinitionId)
		elseif check.Kind == "Rank" then
			return rankId(data) == check.RankId
		end
		return false
	end

	local function progressFor(step: any, data: any): any?
		local progress = step.Progress
		if type(progress) ~= "table" then
			return nil
		end
		if progress.Kind == "SkillLevel" then
			return { Current = math.min(skillLevel(data, progress.SkillId), progress.Level), Required = progress.Level }
		elseif progress.Kind == "Gold" then
			local gold = if type(data.Gold) == "number" then data.Gold else 0
			return { Current = math.min(math.max(gold, 0), progress.Threshold), Required = progress.Threshold }
		end
		return nil
	end

	local function targetFor(step: any): any?
		local target = step.Target
		if type(target) ~= "table" then
			return nil
		end
		local copy: any = { Tag = target.Tag }
		if target.MatchAttribute ~= nil then
			copy.MatchAttribute = target.MatchAttribute
			copy.MatchValue = target.MatchValue
		end
		return copy
	end

	-- Sanitized onboarding view for the read model: the current step (title/hint/progress/target) or a
	-- completion marker. Never exposes raw progression-flag storage; the client only learns the derived
	-- step and progress, so it cannot infer or assert internal completion state.
	function service.GetView(userId: number): (any?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		local data = playerData.GetSnapshot(userId)
		if not data then
			return nil, "NotReady"
		end
		local total = #Definitions.Ordered
		for index, step in Definitions.Ordered do
			if not stepComplete(step, data) then
				return {
					Complete = false,
					StepId = step.Id,
					Index = index,
					Total = total,
					Title = step.Title,
					Hint = step.Hint,
					Progress = progressFor(step, data),
					Target = targetFor(step),
				}, nil
			end
		end
		-- Every step satisfied: mandatory onboarding is finished.
		return { Complete = true, Index = total, Total = total }, nil
	end

	-- Sets a one-time progression flag, skipping the write when it is already set. Fail-closed: an
	-- invalid user or an unready session records nothing.
	local function setFlagOnce(userId: number, flagId: string): (boolean, string?)
		if not validUserId(userId) then
			return false, "InvalidUserId"
		end
		local data = playerData.GetSnapshot(userId)
		if not data then
			return false, "NotReady"
		end
		if flagSet(data, flagId) then
			return true, nil
		end
		return playerData.Update(userId, function(d)
			d.ProgressionFlags[flagId] = true
		end)
	end

	-- Records the starter-focus acknowledgement (a one-time UI confirmation). This is the ONLY
	-- onboarding write a client request may trigger, and it grants nothing but the flag itself.
	function service.AcknowledgeStarterFocus(userId: number): (any?, string?)
		local ok, reason = setFlagOnce(userId, Flags.OnboardingStarterFocusAcknowledged)
		if not ok then
			return nil, reason or "PlayerDataUpdateFailed"
		end
		return { Acknowledged = true }, nil
	end

	-- Called by CombatRewards on the hit that consumes a normal enemy's death, with that enemy's
	-- definition id. The milestone is specifically "first Goblin defeated", so any non-Goblin normal
	-- enemy (a future archetype) records nothing. Idempotent and best-effort.
	function service.NoteGoblinDefeated(userId: number, definitionId: any): (boolean, string?)
		if definitionId ~= EnemyIds.Goblin then
			return false, "NotGoblin"
		end
		return setFlagOnce(userId, Flags.OnboardingFirstGoblinDefeated)
	end

	-- Called after a successful Gathering settlement that actually awarded ore, with the awarded item's
	-- definition id. Only Iron Ore counts, so buying ore or an external grant -- neither of which flows
	-- through here -- can never satisfy the Mining objective.
	function service.NoteOreGathered(userId: number, oreDefinitionId: any): (boolean, string?)
		if oreDefinitionId ~= Definitions.IronOreDefinitionId then
			return false, "NotIronOre"
		end
		return setFlagOnce(userId, Flags.OnboardingFirstOreGathered)
	end

	-- Called after a successful craft, with the completed recipe id. Only the Iron Bar recipe counts,
	-- so merely owning a bar (bought, granted, or received another way) never satisfies Smelting.
	function service.NoteBarSmithed(userId: number, recipeId: any): (boolean, string?)
		if recipeId ~= Definitions.IronBarRecipeId then
			return false, "NotIronBarRecipe"
		end
		return setFlagOnce(userId, Flags.OnboardingFirstBarSmithed)
	end

	-- Reconciles the state-derivable historical milestones and grants the once-only post-training Gold
	-- reward. Called after each successful request so heartbeat-driven progress (training XP, gathered
	-- ore) latches promptly. Cheap in steady state: it snapshots first and only opens a transaction when
	-- something is actually pending. Every latch is re-evaluated on the transactional data so a
	-- concurrent change cannot cause a stale write. Never raises; callers wrap it defensively.
	function service.Settle(userId: number)
		if not validUserId(userId) then
			return
		end
		local data = playerData.GetSnapshot(userId)
		if not data then
			return
		end

		local rewardDue = (not flagSet(data, Flags.OnboardingTrainingRewardGranted))
			and skillLevel(data, SkillIds.Melee) >= Definitions.MeleeTargetLevel
			and skillLevel(data, SkillIds.Defense) >= Definitions.DefenseTargetLevel
		local goldDue = (not flagSet(data, Flags.OnboardingGoldMilestoneReached))
			and type(data.Gold) == "number" and data.Gold >= Definitions.GoldMilestoneGold
		local upgradeDue = (not flagSet(data, Flags.OnboardingUpgradedWeaponAcquired))
			and ownsDefinition(data, Definitions.UpgradedWeaponDefinitionId)

		-- First-ore and first-bar are NOT reconciled here: they must be proven by an actual gathering
		-- award / Iron Bar craft (see NoteOreGathered / NoteBarSmithed), never by inventory presence.
		if not (rewardDue or goldDue or upgradeDue) then
			return
		end

		playerData.Update(userId, function(d)
			local flags = d.ProgressionFlags
			if type(flags) ~= "table" then
				return
			end
			-- Post-training Gold reward: granted exactly once, atomically with its flag, only if the
			-- authoritative levels still hold on the transactional data. If the credit itself fails
			-- (e.g. Gold cap), the flag stays unset so it is retried rather than lost.
			if not flags[Flags.OnboardingTrainingRewardGranted]
				and skillLevel(d, SkillIds.Melee) >= Definitions.MeleeTargetLevel
				and skillLevel(d, SkillIds.Defense) >= Definitions.DefenseTargetLevel
			then
				local newGold = economy.CreditGoldToData(d, Definitions.TrainingRewardGold)
				if newGold then
					flags[Flags.OnboardingTrainingRewardGranted] = true
				end
			end
			if not flags[Flags.OnboardingGoldMilestoneReached] and type(d.Gold) == "number" and d.Gold >= Definitions.GoldMilestoneGold then
				flags[Flags.OnboardingGoldMilestoneReached] = true
			end
			if not flags[Flags.OnboardingUpgradedWeaponAcquired] and ownsDefinition(d, Definitions.UpgradedWeaponDefinitionId) then
				flags[Flags.OnboardingUpgradedWeaponAcquired] = true
			end
		end)
	end

	return table.freeze(service)
end

return table.freeze(Service)
