-- Run once against sqldb-app as a member of the SQL admin Entra ID group
-- (Azure Data Studio / sqlcmd with Microsoft Entra authentication).
-- Replace the names with the web app name and its staging slot.
-- The slot's managed identity is named "<app-name>/slots/staging".

CREATE USER [app-alz-dev-xxxx] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [app-alz-dev-xxxx];
ALTER ROLE db_datawriter ADD MEMBER [app-alz-dev-xxxx];

CREATE USER [app-alz-dev-xxxx/slots/staging] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [app-alz-dev-xxxx/slots/staging];
ALTER ROLE db_datawriter ADD MEMBER [app-alz-dev-xxxx/slots/staging];

-- Least privilege: no db_owner, no DDL rights for the application.
