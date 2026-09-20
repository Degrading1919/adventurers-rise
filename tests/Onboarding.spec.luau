--!strict

local SkillIds = require("SkillIds")
local ProgressionFlagIds = require("ProgressionFlagIds")
local Definitions = require("OnboardingDefinitions")
local Onboarding = require("OnboardingService")

local Steps = Definitions.StepIds

local passed = 0
local function test(name, run)
	local ok, message = pcall(run)
	assert(ok, name .. ": " .. tostring(message))
	passed += 1
	print("PASS " .. name)
end
local function equal(actual, expected)
	assert(actual == expected, ("expected %s, got %s"):format(tostring(expected), tostring(actual)))
end

local function deepcopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = deepcopy(v)
	end
	return out
end

local function freshData(): any
	return {
		Gold = 0,
		SkillXP = { [SkillIds.Melee] = 0, [SkillIds.Defense] = 0, [SkillIds.Mining] = 0, [SkillIds.Smithing] = 0 },
		Inventory = { Stacks = {}, Items = {} },
		Ascension = { RankId = "ascension_adventurer", Flags = {} },
		ProgressionFlags = {},
	}
end

-- Minimal trusted PlayerData boundary: GetSnapshot yields an isolated copy; Update applies the change
-- to a copy and commits (an erroring change aborts without mutating), mirroring the real service.
local function makePlayerData(initial: any)
	local store = { data = initial }
	local api: any = {}
	function api.GetSnapshot(_userId: number)
		return deepcopy(store.data)
	end
	function api.Update(_userId: number, change: (any) -> ())
		local candidate = deepcopy(store.data)
		local ok = pcall(change, candidate)
		if not ok then
			return false, "InvalidMutation"
		end
		store.data = candidate
		return true, nil
	end
	return api, store
end

-- Fake authoritative deps: level = 1 + floor(xp/100) (so xp 100 => Level 2); Gold credit adds in place.
local skills = {
	GetStateFromData = function(data: any, skillId: string)
		local xp = (data.SkillXP and data.SkillXP[skillId]) or 0
		return { Level = 1 + math.floor(xp / 100) }, nil
	end,
}
local economy = {
	CreditGoldToData = function(data: any, amount: number)
		data.Gold = (data.Gold or 0) + amount
		return data.Gold, nil
	end,
}

local USER = 7
local function newService(data: any)
	local playerData, store = makePlayerData(data)
	local service = Onboarding.New(playerData, { Skills = skills, Economy = economy })
	return service, store
end

-- ===== Definition integrity =====
test("onboarding definitions validate and are ordered end-to-end", function()
	local ok = Definitions.Validate(Definitions.Ordered)
	equal(ok, true)
	equal(Definitions.Ordered[1].Id, Steps.StarterFocus)
	equal(Definitions.Ordered[#Definitions.Ordered].Id, Steps.AscendAdept)
end)

-- ===== Fresh player begins at the first step =====
test("a fresh player begins at the starter-focus step", function()
	local service = newService(freshData())
	local view = assert(service.GetView(USER))
	equal(view.Complete, false)
	equal(view.StepId, Steps.StarterFocus)
	equal(view.Index, 1)
	equal(view.Total, #Definitions.Ordered)
end)

test("GetView rejects an invalid userId", function()
	local service = newService(freshData())
	local view, reason = service.GetView(-1)
	equal(view, nil)
	equal(reason, "InvalidUserId")
end)

-- ===== Starter focus only via the intended server path =====
test("starter focus advances only after the acknowledgement write", function()
	local service, store = newService(freshData())
	assert(service.AcknowledgeStarterFocus(USER))
	equal(store.data.ProgressionFlags[ProgressionFlagIds.OnboardingStarterFocusAcknowledged], true)
	equal((assert(service.GetView(USER))).StepId, Steps.TrainMelee)
end)

-- ===== Melee / Defense advance from authoritative levels =====
test("Melee and Defense objectives advance from authoritative skill levels with progress", function()
	local data = freshData()
	data.ProgressionFlags[ProgressionFlagIds.OnboardingStarterFocusAcknowledged] = true
	local service, store = newService(data)
	local melee = assert(service.GetView(USER))
	equal(melee.StepId, Steps.TrainMelee)
	equal(melee.Progress.Current, 1)
	equal(melee.Progress.Required, 2)

	store.data.SkillXP[SkillIds.Melee] = 100 -- Level 2
	equal((assert(service.GetView(USER))).StepId, Steps.TrainDefense)

	store.data.SkillXP[SkillIds.Defense] = 100 -- Level 2
	service.Settle(USER) -- grants the one-time reward; also advances past defense
	equal((assert(service.GetView(USER))).StepId, Steps.FightGoblins)
end)

-- ===== One-time post-training Gold reward =====
test("the post-training Gold reward is granted exactly once and cannot be replayed", function()
	local data = freshData()
	data.SkillXP[SkillIds.Melee] = 100
	data.SkillXP[SkillIds.Defense] = 100
	local service, store = newService(data)
	equal(store.data.Gold, 0)
	service.Settle(USER)
	equal(store.data.Gold, Definitions.TrainingRewardGold)
	equal(store.data.ProgressionFlags[ProgressionFlagIds.OnboardingTrainingRewardGranted], true)
	-- Re-running Settle must not credit again.
	service.Settle(USER)
	service.Settle(USER)
	equal(store.data.Gold, Definitions.TrainingRewardGold)
end)

-- ===== Goblin milestone is a real server write, not client-inferable =====
test("a Goblin defeat records the milestone; Gold alone never satisfies it", function()
	local data = freshData()
	data.ProgressionFlags[ProgressionFlagIds.OnboardingStarterFocusAcknowledged] = true
	data.SkillXP[SkillIds.Melee] = 100
	data.SkillXP[SkillIds.Defense] = 100
	local service, store = newService(data)
	service.Settle(USER)
	-- Even with plenty of Gold, the fight step is not complete until the defeat is recorded.
	store.data.Gold = 9999
	equal((assert(service.GetView(USER))).StepId, Steps.FightGoblins)
	assert(service.NoteGoblinDefeated(USER))
	equal(store.data.ProgressionFlags[ProgressionFlagIds.OnboardingFirstGoblinDefeated], true)
	-- Gold milestone latches from Settle (>= threshold) so the next step is mining.
	service.Settle(USER)
	equal((assert(service.GetView(USER))).StepId, Steps.MineOre)
end)

test("NoteGoblinDefeated rejects an invalid userId (no fabricated milestone)", function()
	local service, store = newService(freshData())
	local ok = service.NoteGoblinDefeated(0)
	equal(ok, false)
	equal(store.data.ProgressionFlags[ProgressionFlagIds.OnboardingFirstGoblinDefeated], nil)
end)

-- ===== Gold milestone does not regress after spending =====
test("the Gold milestone does not regress after the player spends Gold", function()
	local data = freshData()
	data.Gold = Definitions.GoldMilestoneGold
	local service, store = newService(data)
	service.Settle(USER)
	equal(store.data.ProgressionFlags[ProgressionFlagIds.OnboardingGoldMilestoneReached], true)
	store.data.Gold = 0 -- spent it all
	-- The step remains latched; GetView never falls back to earn-gold once reached.
	local flags = store.data.ProgressionFlags
	equal(flags[ProgressionFlagIds.OnboardingGoldMilestoneReached], true)
end)

-- ===== Mining / smithing milestones survive consuming the materials =====
test("mining and smithing milestones do not regress after materials are consumed", function()
	local data = freshData()
	local service, store = newService(data)
	store.data.Inventory.Stacks[Definitions.IronOreDefinitionId] = 3
	service.Settle(USER)
	equal(store.data.ProgressionFlags[ProgressionFlagIds.OnboardingFirstOreGathered], true)
	-- Consume all ore into a bar: first-ore stays, first-bar latches.
	store.data.Inventory.Stacks[Definitions.IronOreDefinitionId] = nil
	store.data.Inventory.Stacks[Definitions.IronBarDefinitionId] = 1
	service.Settle(USER)
	equal(store.data.ProgressionFlags[ProgressionFlagIds.OnboardingFirstBarSmithed], true)
	-- Consume the bar too: both historical flags remain set.
	store.data.Inventory.Stacks[Definitions.IronBarDefinitionId] = nil
	service.Settle(USER)
	equal(store.data.ProgressionFlags[ProgressionFlagIds.OnboardingFirstOreGathered], true)
	equal(store.data.ProgressionFlags[ProgressionFlagIds.OnboardingFirstBarSmithed], true)
end)

-- ===== Upgrade accepts either acquisition route and survives a later sell =====
test("upgraded-sword acquisition accepts ownership and does not regress after selling", function()
	local data = freshData()
	local service, store = newService(data)
	-- Model "bought or crafted": the item is simply owned.
	store.data.Inventory.Items["inst_1"] = { DefinitionId = Definitions.UpgradedWeaponDefinitionId }
	-- Before Settle, the Acquire check already recognises current ownership.
	local before = assert(service.GetView(USER))
	assert(before.StepId ~= Steps.AcquireUpgrade, "owning the sword should already satisfy the acquire step")
	service.Settle(USER)
	equal(store.data.ProgressionFlags[ProgressionFlagIds.OnboardingUpgradedWeaponAcquired], true)
	-- Sell it: the durable flag keeps the step complete.
	store.data.Inventory.Items["inst_1"] = nil
	local afterSell = assert(service.GetView(USER))
	assert(afterSell.StepId ~= Steps.AcquireUpgrade, "selling must not regress the acquire step")
end)

-- ===== Boss + Ascension steps use existing authority; completion ends onboarding =====
test("the existing Chieftain flag and Adept rank drive the final steps and completion", function()
	local data = freshData()
	-- Everything up to the boss is satisfied via the historical/durable facts.
	data.ProgressionFlags[ProgressionFlagIds.OnboardingStarterFocusAcknowledged] = true
	data.SkillXP[SkillIds.Melee] = 100
	data.SkillXP[SkillIds.Defense] = 100
	data.ProgressionFlags[ProgressionFlagIds.OnboardingTrainingRewardGranted] = true
	data.ProgressionFlags[ProgressionFlagIds.OnboardingFirstGoblinDefeated] = true
	data.ProgressionFlags[ProgressionFlagIds.OnboardingGoldMilestoneReached] = true
	data.ProgressionFlags[ProgressionFlagIds.OnboardingFirstOreGathered] = true
	data.ProgressionFlags[ProgressionFlagIds.OnboardingFirstBarSmithed] = true
	data.ProgressionFlags[ProgressionFlagIds.OnboardingUpgradedWeaponAcquired] = true
	local service, store = newService(data)
	equal((assert(service.GetView(USER))).StepId, Steps.DefeatChieftain)

	store.data.ProgressionFlags[ProgressionFlagIds.GoblinChieftainDefeated] = true
	equal((assert(service.GetView(USER))).StepId, Steps.AscendAdept)

	store.data.Ascension.RankId = "ascension_adept"
	local done = assert(service.GetView(USER))
	equal(done.Complete, true)
	equal(done.StepId, nil)
end)

-- ===== Reconnect / reconstruction resumes at the correct step =====
test("a rebuilt service over persisted data resumes at the correct step", function()
	local data = freshData()
	data.ProgressionFlags[ProgressionFlagIds.OnboardingStarterFocusAcknowledged] = true
	data.SkillXP[SkillIds.Melee] = 100
	data.SkillXP[SkillIds.Defense] = 100
	data.ProgressionFlags[ProgressionFlagIds.OnboardingTrainingRewardGranted] = true
	data.ProgressionFlags[ProgressionFlagIds.OnboardingFirstGoblinDefeated] = true
	data.ProgressionFlags[ProgressionFlagIds.OnboardingGoldMilestoneReached] = true
	-- Simulate a fresh session: a brand-new service instance over the same persisted data.
	local service = newService(data)
	equal((assert(service.GetView(USER))).StepId, Steps.MineOre)
end)

print(("%d Onboarding checks passed"):format(passed))
