--!strict

-- Register released raw-document migrations explicitly in ascending target
-- versions. The MigrationModule performs the final deterministic sort.
--
-- Set LegacyBaselineVersion only when a real released profile predates the
-- Version provider and its exact schema baseline is known. Leaving it nil
-- makes a non-empty profile without a checkpoint fail closed.
type Manifest = {
	Controllers: { any },
	LegacyBaselineVersion: string?,
}

local manifest: Manifest = {
	Controllers = table.freeze({}),
	LegacyBaselineVersion = nil,
}

return table.freeze(manifest)
