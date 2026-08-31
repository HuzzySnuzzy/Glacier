-- ModuleScript: Registry
-- Parent: Glacier1
--
-- Shared handle between server scripts. Replaces _G, which is a separate
-- environment per VM and gives no error when the producer hasn't run yet --
-- you just read nil and guess why.

return {}