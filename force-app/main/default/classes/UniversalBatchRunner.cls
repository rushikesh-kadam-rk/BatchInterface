public class UniversalBatchRunner implements Database.Batchable<SObject>, Database.Stateful {

    private IBatchWorker worker;
    //private List<Batch_Log__c> errorLogs;

    public UniversalBatchRunner(IBatchWorker worker) {
        this.worker = worker;
        //this.errorLogs = new List<Batch_Log__c>();
    }

    public static Id start(IBatchWorker worker) {
        // 1. Configuration Lookup
        Integer size = 200;
        Boolean isActive = true;
        
        try {
            Batch_Configuration__mdt config = [
                SELECT Batch_Size__c, Is_Active__c
                FROM Batch_Configuration__mdt 
                WHERE DeveloperName = :worker.getBatchName() 
                LIMIT 1
            ];
            
            if (config.Is_Active__c == false) {
                System.debug('Job Disabled: ' + worker.getBatchName());
                return null;
            }
            if (config.Batch_Size__c != null && config.Batch_Size__c > 0) {
                size = Integer.valueOf(config.Batch_Size__c);
            }
        } catch (Exception e) {
            System.debug('Using defaults for: ' + worker.getBatchName());
        }

        // 2. Execution
        UniversalBatchRunner runner = new UniversalBatchRunner(worker);
        return Database.executeBatch(runner, size);
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        // The worker constructs the query string including the dynamic WHERE clause
        return Database.getQueryLocator(worker.getQuery());
    }

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        try {
            worker.processRecords(scope);
        } catch (Exception e) {
            // Batch_Log__c log = new Batch_Log__c();
            // log.Job_Name__c = worker.getBatchName();
            // log.Error_Message__c = e.getMessage();
            // log.Stack_Trace__c = e.getStackTraceString();
            // log.Timestamp__c = System.now();
            // errorLogs.add(log);
        }
    }

    public void finish(Database.BatchableContext bc) {
        //if (!errorLogs.isEmpty()) insert errorLogs;
        worker.onFinish(bc);
        
        IBatchWorker nextWorker = worker.getNextWorker();
        if (nextWorker != null) UniversalBatchRunner.start(nextWorker);
    }
}