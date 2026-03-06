### New feature to add

- In settings, allow me to connect Salesforce using OAuth (keep in mind we’ll probably add more CRMs in the future)
    - Create a Salesforce OAuth app / “Connected App” for OAuth. There are public docs, multiple sandbox types and free Developer Edition orgs.
- After you record a new meeting:
    - Allow me to open a modal where I can review suggested updates to a Salesforce contact
    - Show a search/select where I can search for a Salesforce contact
    - Use the Salesforce API to pull the contact record
    - Use AI to generate a list of suggested updates to the Salesforce record
        - For example, if the user mentioned “My phone number is 8885550000 it suggests updating their phone number in the CRM”
    - It should show the existing value in Salesforce and the AI suggested update to the field
    - After reviewing the updates, I can click “Update Salesforce” and it will sync the updates to the selected Salesforce contact.
