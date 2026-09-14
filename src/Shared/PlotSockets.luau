--!strict

local sockets: { [string]: string } = {
	Melee = "socket_melee",
	Defense = "socket_defense",
	Ranged = "socket_ranged",
	Magic = "socket_magic",
	Forge = "socket_forge",
	Fletching = "socket_fletching",
	Arcana = "socket_arcana",
}

local byId: { [string]: boolean } = {}
for _, socketId in sockets do
	byId[socketId] = true
end

return table.freeze({
	Melee = sockets.Melee,
	Defense = sockets.Defense,
	Ranged = sockets.Ranged,
	Magic = sockets.Magic,
	Forge = sockets.Forge,
	Fletching = sockets.Fletching,
	Arcana = sockets.Arcana,
	ById = table.freeze(byId),
})
