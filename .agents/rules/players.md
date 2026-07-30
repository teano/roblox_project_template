# Players lifecycle rules

## Scope

Apply to player joins/leaves, character spawn/removal, player lookup, character lookup, and cleanup tied to Roblox `Players`.

## Mandatory rules

- Server systems MUST consume player and character lifecycle through `ServerScriptService.Modules.Players.PlayersModule`.
- Client systems MUST consume local player and character lifecycle through `ReplicatedStorage.Client.Players.PlayersModule`.
- `PlayersModule` is the only project wrapper that subscribes directly to platform player/character lifecycle events.
- `ObservePlayers` consumers MUST handle players already present at subscription time.
- Existing-player enumeration MUST confirm that a player is still present before delivery.
- Observer membership MUST be cleared on player removal even when the consumer does not request an `onRemoving` callback.
- Player removal cleanup MUST be idempotent because shutdown and removal paths may overlap.
- Character-bound resources MUST be disconnected or destroyed on character removal/destruction.
- Save loading and closing remain subscribers of `PlayersModule`; they do not belong inside the wrapper.

## Forbidden patterns

- MUST NOT scatter new `Players.PlayerAdded` or `PlayerRemoving` connections across modules.
- MUST NOT assume the initialization command subscribes before the first player exists.
- MUST NOT use character ancestry alone as player identity when `GetPlayerFromCharacter` is available.
- MUST NOT place save, Wallet, another domain provider, or gameplay logic
  inside `PlayersModule`.

## Positive example

```lua
playersModule.CharacterAdded:Connect(function(player, character)
	attachRuntime(player, character)
end)
```

## Negative example

```lua
game:GetService("Players").PlayerAdded:Connect(function(player)
	loadSaveAndStartGameplay(player)
end)
```

This duplicates lifecycle ownership and couples unrelated systems.

## Verification

- Test existing players, join, leave, character respawn, and repeated cleanup.
- Run save/shutdown integration tests when player removal behavior changes.
