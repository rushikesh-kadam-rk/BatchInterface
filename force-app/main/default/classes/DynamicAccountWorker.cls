public class DynamicAccountWorker implements IBatchWorker {
    
    // Internal state to hold parameters
    private Map<String, Object> queryParams;
    
    // Constructor initializes map to avoid null pointers
    public DynamicAccountWorker() {
        this.queryParams = new Map<String, Object>();
    }

    // FEATURE 3: Set Parameters
    public void setQueryParams(Map<String, Object> params) {
        this.queryParams = params;
    }

    // 1. DYNAMIC QUERY
    public String getQuery() {
        // Default to 'Old' if no param is passed
        String statusTarget = 'Old';
        if (queryParams.containsKey('targetStatus')) {
            statusTarget = (String) queryParams.get('targetStatus');
        }
        
        // Construct query dynamically
        return 'SELECT Id, Status__c FROM Account WHERE Status__c = \'' + String.escapeSingleQuotes(statusTarget) + '\'';
    }

    public String getBatchName() {
        return 'Dynamic_Account_Worker'; 
    }

    public void processRecords(List<SObject> scope) {
        // Logic here...
    }

    public void onFinish(Database.BatchableContext bc) {
        System.debug('Finished processing for status: ' + queryParams.get('targetStatus'));
    }
    
    public IBatchWorker getNextWorker() {
        return null; 
    }
}