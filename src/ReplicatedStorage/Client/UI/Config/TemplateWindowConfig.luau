--!strict

local Definitions = script.Parent.Definitions

return table.freeze({
	require(Definitions.InviteFriendsWindowDefinition),
	require(Definitions.GroupInviteWindowDefinition),
})
