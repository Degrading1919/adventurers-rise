--!strict

-- Stable, centralized event IDs for the one-way server -> client presentation channel (see
-- Composition/PlayerEvents.luau). Mirrors RequestIds' shape. These identify sanitized, player-specific
-- presentation events pushed to the owning client. They carry no authority: the client cannot use one
-- to request or award anything, and the server never grants gameplay from an event.
local ids: { [string]: string } = {
	BossPersonalReward = "boss_personal_reward",
}

local byId: { [string]: boolean } = {}
for _, id in ids do
	byId[id] = true
end

local EventIds: { [string]: any } = table.clone(ids)
EventIds.ById = table.freeze(byId)

return table.freeze(EventIds)
