# gmail-backup
Backup enterprise users' Google email account data.
Use Google's new Email Audit API to backup the mailboxes of any enterprise users for whom you have administrative access to their email accounts. This only works with Google Apps Enteprise accounts.

Google Apps Email Audit API documentation: https://developers.google.com/admin-sdk/email-audit/

Use gmail-backup.rb to start the backups.
Use gmail-backup-status.rb to check the status of the backups, and obtain the download URLs for the backed up mailbox files when they are complete. It may take up to three days for the backup requests to complete.

