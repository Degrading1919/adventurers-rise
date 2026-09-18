--!strict

-- The smallest injected contract between repository composition and the physical Studio scene.
-- Combat and Gathering need real-world distance/eligibility, and Training/Forge interactions need
-- real player-to-station and player-to-Forge proximity, that repository code cannot truthfully
-- invent; Studio-context work implements the real versions and Bootstrap injects them. Until that
-- exists, Bootstrap may fall back to the fail-closed placeholders below, which clearly report the
-- missing boundary instead of fabricating a fake target/node/proximity.
export type CombatDistanceProvider = (number, any) -> (number?, string?)
export type GatheringNodeResolver = (number, string) -> (any?, string?)
export type StationDistanceProvider = (number, string) -> (number?, string?)
export type ForgeDistanceProvider = (number) -> (number?, string?)
export type WorldAdapters = {
	CombatDistanceProvider: CombatDistanceProvider,
	GatheringNodeResolver: GatheringNodeResolver,
	StationDistanceProvider: StationDistanceProvider,
	ForgeDistanceProvider: ForgeDistanceProvider,
}

local WorldAdapters = {}

function WorldAdapters.FailClosedCombatDistanceProvider(): CombatDistanceProvider
	return function(_attackerUserId: number, _enemyState: any): (number?, string?)
		return nil, "WorldAdapterNotConfigured"
	end
end

function WorldAdapters.FailClosedGatheringNodeResolver(): GatheringNodeResolver
	return function(_userId: number, _nodeId: string): (any?, string?)
		return nil, "WorldAdapterNotConfigured"
	end
end

function WorldAdapters.FailClosedStationDistanceProvider(): StationDistanceProvider
	return function(_userId: number, _stationId: string): (number?, string?)
		return nil, "WorldAdapterNotConfigured"
	end
end

function WorldAdapters.FailClosedForgeDistanceProvider(): ForgeDistanceProvider
	return function(_userId: number): (number?, string?)
		return nil, "WorldAdapterNotConfigured"
	end
end

return table.freeze(WorldAdapters)
