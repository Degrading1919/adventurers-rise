--!strict

-- The smallest injected contract between repository composition and the physical Studio scene.
-- Combat and Gathering both need real-world information (attacker/target distance, node
-- eligibility) that repository code cannot truthfully invent; Studio-context work implements the
-- real versions of these two functions and Bootstrap injects them. Until that exists, Bootstrap
-- may fall back to the fail-closed placeholders below, which clearly report the missing boundary
-- instead of fabricating a fake target/node.
export type CombatDistanceProvider = (number, any) -> (number?, string?)
export type GatheringNodeResolver = (number, string) -> (any?, string?)
export type WorldAdapters = {
	CombatDistanceProvider: CombatDistanceProvider,
	GatheringNodeResolver: GatheringNodeResolver,
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

return table.freeze(WorldAdapters)
