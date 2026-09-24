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
local ARMOR_PREFIX = "AR_ArmorVisual_"

-- Armour is shown as a simple tinted shell welded over a body part (placeholder until rigged meshes
-- land; the seam is identical to the weapon/tool templates). R15 primary, R6 fallback.
local ARMOR_LIMBS: { [string]: string } = {
	[EquipmentSlots.Head] = "Head",
	[EquipmentSlots.Body] = "UpperTorso",
	[EquipmentSlots.Legs] = "LowerTorso",
}
local ARMOR_LIMB_FALLBACKS: { [string]: string } = {
	UpperTorso = "Torso",
	LowerTorso = "Torso",
}
-- Tint by material tier so iron vs steel reads at a glance; keyed by the item id's tier prefix.
local function armorColor(definitionId: string): Color3
	if string.find(definitionId, "steel", 1, true) then
		return Color3.fromRGB(120, 140, 170) -- steel: cool blue-grey
	end
	return Color3.fromRGB(175, 176, 182) -- iron: plain grey
end

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
		local limbName = SLOT_LIMBS[slotId]
		local limb = limbFor(character, limbName)
		if not limb then
			return
		end

		local library = templatesFolder()
		local template = library and library:FindFirstChild(definitionId)
		local model: Model
		if template and template:IsA("Model") and (template :: Model).PrimaryPart ~= nil then
			model = (template :: Model):Clone()
		else
			-- Procedural placeholder so a held item always reads even before art import (mirrors the armour
			-- shells): a metal blade for weapons, a wooden haft for tools. Same weld/grip path as templates.
			model = Instance.new("Model")
			local held = Instance.new("Part")
			held.Name = "Placeholder"
			if slotId == EquipmentSlots.Weapon then
				held.Size = Vector3.new(0.22, 3, 0.22)
				held.Color = Color3.fromRGB(205, 210, 220)
				held.Material = Enum.Material.Metal
			else
				held.Size = Vector3.new(0.3, 2.4, 0.3)
				held.Color = Color3.fromRGB(120, 85, 55)
				held.Material = Enum.Material.Wood
			end
			held.TopSurface = Enum.SurfaceType.Smooth
			held.BottomSurface = Enum.SurfaceType.Smooth
			held.Parent = model
			model.PrimaryPart = held
		end
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

	local function armorLimbFor(character: Model, limbName: string): BasePart?
		local part = character:FindFirstChild(limbName)
		if not part then
			local fallback = ARMOR_LIMB_FALLBACKS[limbName]
			part = fallback and character:FindFirstChild(fallback)
		end
		if part and part:IsA("BasePart") then
			return part
		end
		return nil
	end

	local function removeArmorVisual(character: Model, slotId: string)
		local existing = character:FindFirstChild(ARMOR_PREFIX .. slotId)
		if existing then
			existing:Destroy()
		end
		shown[slotId] = nil
	end

	-- Placeholder armour: a tinted shell part welded over the body part, slightly larger so it reads as
	-- worn plate. Same clean replacement seam as the weapon/tool templates (swap for rigged meshes later).
	local function attachArmorVisual(character: Model, slotId: string, definitionId: string)
		local limbName = ARMOR_LIMBS[slotId]
		local limb = if limbName then armorLimbFor(character, limbName) else nil
		if not limb then
			return
		end
		local shell = Instance.new("Part")
		shell.Name = ARMOR_PREFIX .. slotId
		shell.Size = limb.Size * 1.12
		shell.Color = armorColor(definitionId)
		shell.Material = Enum.Material.Metal
		shell.Transparency = 0.25
		shell.Anchored = false
		shell.CanCollide = false
		shell.CanQuery = false
		shell.CanTouch = false
		shell.Massless = true
		shell.CFrame = limb.CFrame
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = limb
		weld.Part1 = shell
		weld.Parent = shell
		shell.Parent = character
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

		-- Armour slots: the same reconciliation, but as tinted body shells rather than held templates.
		for slotId in ARMOR_LIMBS do
			local desired: string? = nil
			if type(equipment) == "table" then
				local slot = equipment[slotId]
				if type(slot) == "table" and type(slot.DefinitionId) == "string" then
					desired = slot.DefinitionId
				end
			end
			local current = shown[slotId]
			local present = character:FindFirstChild(ARMOR_PREFIX .. slotId) ~= nil
			if desired ~= current or (desired ~= nil and not present) then
				removeArmorVisual(character, slotId)
				if desired ~= nil then
					attachArmorVisual(character, slotId, desired)
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
