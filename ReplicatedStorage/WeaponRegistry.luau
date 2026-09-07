-- ModuleScript: ReplicatedStorage.WeaponRegistry
--
-- KEPT AS A FORWARDER. The lookup moved to ItemRegistry when weapons stopped
-- being the only thing you can hold -- a weapon is now an item with a fire
-- rate -- and this exists so the dozen modules that require WeaponRegistry
-- keep working unchanged.
--
-- New code should require ItemRegistry directly. This is not deprecated in
-- the sense of "about to break": it is one table lookup and it will keep
-- resolving weapons for as long as anything asks it to.

return require(game:GetService("ReplicatedStorage"):WaitForChild("ItemRegistry"))
