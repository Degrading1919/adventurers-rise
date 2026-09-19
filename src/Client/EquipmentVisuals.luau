--!strict

-- Client presentation seam: shows the player's currently equipped weapon/tool on their own character.
--
-- This is display only. It never decides what is equipped -- it mirrors the authoritative Equipment
-- snapshot the read model already delivers (Controller polls it), cloning a production mesh keyed by
-- the item's stable DefinitionId from ReplicatedStorage.AR_Assets.Equipment and welding it to a hand.
-- No gameplay state is read or written here; if the asset library or a template is missing it is a
-- silent no-op, so the client still runs in a place that has not imported the meshes.
--
-- Scope: it renders the LOCAL player's own equipped items. Replicating other players' equipped meshes
-- would require a server-authoritative character-attachment channel that does not exist yet; that is a
-- larger, separate seam and is intentionally out of scope for this presentation-only module.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local EquipmentSlots = require(Shared:WaitForChild("EquipmentSlots"))

-- Which character limb each slot's visual is welded to, and the grip offset (relative to that limb's
-- CFrame) applied to the cloned model's pivot. Weapon in the right hand, tool in the left, so the
-- sword and pickaxe progressions are both visible at once. Values are tuned for the R15 rig; the meshes
-- were centred on their pivot at import, so the grip pushes the pivot out of the palm and orients the
-- length of the item away from the hand.
local SLOT_LIMBS: { [string]: string } = {
	[EquipmentSlots.Weapon] = "RightHand",
	[EquipmentSlots.Tool] = "LeftHand",
}
-- Tuned against an R15 rig (see the Studio grip-test) so both the sword and pickaxe families read as
-- held: sword blade-up beside the weapon hand, pickaxe head-up with the haft down by the tool hand.
local SLOT_GRIPS: { [string]: CFrame } = {
	[EquipmentSlots.Weapon] = CFrame.new(0, -0.2, -1.1) * CFrame.Angles(math.rad(90), 0, 0),
	[EquipmentSlots.Tool] = CFrame.new(0, -1.1, -0.15) * CFrame.Angles(math.rad(90), 0, 0),
}
-- Older R6 characters name the limbs differently; fall back so the visual still attaches somewhere sane.
local LIMB_FALLBACKS: { [string]: string } = {
	RightHand = "Right Arm",
	LeftHand = "Left Arm",
}

local ATTACHMENT_PREFIX = "AR_EquipVisual_"

local EquipmentVisuals = {}

local function templatesFolder(): Instance?
	local assets = ReplicatedStorage:FindFirstChild("AR_Assets")
	return assets and assets:FindFirstChild("Equipment")
end

function EquipmentVisuals.New(player: Player)
	local self = {}

	-- slotId -> DefinitionId currently shown, so a steady equip state never rebuilds the weld each poll.
	local shown: { [string]: string } = {}
	local shownCharacter: Model? = nil

	local function limbFor(character: Model, limbName: string): BasePart?
		local part = character:FindFirstChild(limbName)
		if not part then
			local fallback = LIMB_FALLBACKS[limbName]
			part = fallback and character:FindFirstChild(fallback)
		end
		if part and part:IsA("BasePart") then
			return part
		end
		return nil
	end

	local function removeVisual(character: Model, slotId: string)
		local existing = character:FindFirstChild(ATTACHMENT_PREFIX .. slotId)
		if existing then
			existing:Destroy()
		end
		shown[slotId] = nil
	end

	local function attachVisual(character: Model, slotId: string, definitionId: string)
		local library = templatesFolder()
		local template = library and library:FindFirstChild(definitionId)
		if not template or not template:IsA("Model") or template.PrimaryPart == nil then
			return
		end
		local limbName = SLOT_LIMBS[slotId]
		local limb = limbFor(character, limbName)
		if not limb then
			return
		end

		local model = (template :: Model):Clone()
		model.Name = ATTACHMENT_PREFIX .. slotId
		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") then
				part.Anchored = false
				part.CanCollide = false
				part.Massless = true
				part.CanQuery = false
				part.CanTouch = false
			end
		end
		local grip = SLOT_GRIPS[slotId] or CFrame.new()
		model:PivotTo(limb.CFrame * grip)
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = limb
		weld.Part1 = model.PrimaryPart
		weld.Parent = model.PrimaryPart
		model.Parent = character
		shown[slotId] = definitionId
	end

	-- Reconcile the shown visuals to an Equipment snapshot: { [slotId] = { DefinitionId = ... } }.
	-- Idempotent -- safe to call every state refresh; only changed slots rebuild.
	function self.Apply(equipment: any)
		local character = player.Character
		if not character then
			-- Character gone (dying/respawning): its visuals died with it; forget them.
			shown = {}
			shownCharacter = nil
			return
		end
		if character ~= shownCharacter then
			-- New body: nothing of ours is on it yet.
			shown = {}
			shownCharacter = character
		end

		for slotId in SLOT_LIMBS do
			local desired: string? = nil
			if type(equipment) == "table" then
				local slot = equipment[slotId]
				if type(slot) == "table" and type(slot.DefinitionId) == "string" then
					desired = slot.DefinitionId
				end
			end
			local current = shown[slotId]
			local present = character:FindFirstChild(ATTACHMENT_PREFIX .. slotId) ~= nil
			if desired ~= current or (desired ~= nil and not present) then
				removeVisual(character, slotId)
				if desired ~= nil then
					attachVisual(character, slotId, desired)
				end
			end
		end
	end

	-- Clear the cache when the character is replaced so the next Apply rebuilds cleanly on the new body.
	player.CharacterAdded:Connect(function()
		shown = {}
		shownCharacter = nil
	end)

	return self
end

return EquipmentVisuals
