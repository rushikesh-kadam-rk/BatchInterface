public class WellMonthAccrualsWorker implements IBatchWorker {

    // --- STATE VARIABLES ---
    private Boolean shouldChainNextJob;
    private Set<Id> wellIdSet;
    private Date startDate;
    private Date endDate;
    private Date revenueEndDate;
    private List<RollupDefinition__mdt> rollupDefinitions;
    private List<String> operatingCoList;
    private String dynamicWhereClause;

    // --- CONSTRUCTORS ---

    // Constructor 1: Full Initialization (Called by Chaining)
    public WellMonthAccrualsWorker(
        Boolean shouldChainNextJob,
        Set<Id> wellIdSet,
        Date startDate,
        Date endDate,
        Date revenueEndDate
    ) {
        this.shouldChainNextJob = (shouldChainNextJob == null) ? true : shouldChainNextJob;
        this.wellIdSet = wellIdSet;
        this.startDate = startDate;
        this.endDate = endDate;
        this.revenueEndDate = revenueEndDate;
        
        initializeConfig();
    }

    // Constructor 2: Default (Called by Scheduler/Manual Run)
    public WellMonthAccrualsWorker() {
        this.shouldChainNextJob = true;
        initializeConfig();
        
        // Load defaults from Global Variable if not passed manually
        List<Global_Variable__c> gvList = [
            SELECT Well_Month_Start_Date__c, Well_Month_End_Date__c, Operating_Company__c 
            FROM Global_Variable__c LIMIT 1
        ];

        if (!gvList.isEmpty()) {
            this.startDate = gvList[0].Well_Month_Start_Date__c;
            this.endDate = gvList[0].Well_Month_End_Date__c;
            this.operatingCoList = gvList[0].Operating_Company__c != null 
                ? gvList[0].Operating_Company__c.split(';') 
                : new List<String>();
        }
    }

    // Helper to load Metadata (Shared logic)
    private void initializeConfig() {
        this.rollupDefinitions = [
            SELECT Parent_Object__c, Parent_Field_To_Update__c, Child_Object__c, 
                   Field_To_Aggregate__c, Aggregate_Function__c, Child_Filter__c, 
                   Batch_Size__c, Process_Group__c, Rollup_Type__c, Active__c
            FROM RollupDefinition__mdt
            WHERE Process_Group__c = 'Accruals' AND Active__c = TRUE
        ];
    }
    
    // --- FRAMEWORK METHODS ---

    public String getBatchName() {
        // Must match a DeveloperName in Batch_Configuration__mdt
        return 'Well_Month_Accruals_Rollup'; 
    }

    // Optional: If you want to use external dynamic filters
    public void setWhereClause(String whereClause) {
        this.dynamicWhereClause = whereClause;
    }

    // --- 1. DYNAMIC QUERY GENERATION ---
    public String getQuery() {
        String query = 'SELECT Id, Oil_Price_Op_Reported_Locked__c, ' +
                       'Gas_Sold_Price_Op_Reported_Locked__c, NGL_Price_Op_Reported_Locked__c ' +
                       'FROM Well_Month__c WHERE ';

        // Convert Dates to String Literals (YYYY-MM-DD) for SOQL
        String dateFilter = 'Well_Month_Date__c >= ' + String.valueOf(startDate) + 
                          ' AND Well_Month_Date__c <= ' + String.valueOf(endDate);

        if (wellIdSet != null && !wellIdSet.isEmpty()) {
            // OPTION A: Filter by specific IDs
            // We join the IDs into a string: ('Id1', 'Id2')
            String idList = '(\'' + String.join(new List<Id>(wellIdSet), '\',\'') + '\')';
            query += 'Well__c IN ' + idList + ' AND ' + dateFilter;
        } else {
            // OPTION B: Filter by DLRS Flag
            query += 'Run_DLRS_Accruals__c = TRUE AND ' + dateFilter;
        }
        
        // Append external where clause if provided
        if (String.isNotBlank(dynamicWhereClause)) {
            query += ' AND (' + dynamicWhereClause + ')';
        }

        return query;
    }

    // --- 2. EXECUTE LOGIC ---
    public void processRecords(List<SObject> scope) {
        List<Well_Month__c> wmScope = (List<Well_Month__c>) scope;
        
        if (wmScope.isEmpty() || rollupDefinitions.isEmpty()) return;

        Set<Id> parentIds = new Set<Id>();
        for (Well_Month__c wm : wmScope) {
            parentIds.add(wm.Id);
        }

        Map<String, Decimal> aggMap = new Map<String, Decimal>();

        // Run Rollup Queries
        for (RollupDefinition__mdt def : rollupDefinitions) {
            String q = 'SELECT ' + def.Aggregate_Function__c + '(' + def.Field_To_Aggregate__c + ') aggVal, ' + 
                       def.Parent_Object__c + ' FROM ' + def.Child_Object__c + 
                       ' WHERE ' + def.Parent_Object__c + ' IN :parentIds';
            
            if (def.Child_Filter__c != null) {
                q += ' AND ' + def.Child_Filter__c;
            }
            if (def.Child_Object__c == 'Well_Payment__c' && revenueEndDate != null) {
                // Use literal for safety in dynamic query context
                q += ' AND Payment_Date__c <= ' + String.valueOf(revenueEndDate);
            }

            q += ' GROUP BY ' + def.Parent_Object__c;

            // Execute Aggregate Query
            // Note: Database.query can bind to local variables like 'parentIds'
            for (SObject record : Database.query(q)) {
                Id parentId = (Id) record.get(def.Parent_Object__c);
                Decimal value = (Decimal) record.get('aggVal');
                if (value == null) value = 0;

                String key = parentId + '|' + def.Parent_Field_To_Update__c;
                aggMap.put(key, aggMap.containsKey(key) ? aggMap.get(key) + value : value);
            }
        }

        // Apply Updates to Memory
        for (Well_Month__c wm : wmScope) {
            for (RollupDefinition__mdt def : rollupDefinitions) {
                String key = wm.Id + '|' + def.Parent_Field_To_Update__c;
                if (aggMap.containsKey(key)) {
                    String target = def.Parent_Field_To_Update__c;
                    
                    // Check Locking Logic
                    Boolean isLocked = 
                        (target == 'Oil_Price_Op_Reported__c' && wm.Oil_Price_Op_Reported_Locked__c == true) ||
                        (target == 'Gas_Sold_Price_Op_Reported__c' && wm.Gas_Sold_Price_Op_Reported_Locked__c == true) ||
                        (target == 'NGL_Price_Op_Reported__c' && wm.NGL_Price_Op_Reported_Locked__c == true);

                    if (isLocked) {
                        System.debug(LoggingLevel.INFO, 'Skipping locked field: ' + target + ' on ' + wm.Id);
                        continue; 
                    }
                    
                    wm.put(target, aggMap.get(key));
                }
            }
        }

        update wmScope;
    }

    // --- 3. FINISH LOGIC ---
    public void onFinish(Database.BatchableContext bc) {
        System.debug('Summarize Well Payments completed.');
    }

    // --- 4. CHAINING LOGIC ---
    public IBatchWorker getNextWorker() {
        if (shouldChainNextJob) {
            
            return new WellMonthTotalLOECapExWorker(
                shouldChainNextJob,
                wellIdSet,
                startDate,
                endDate,
                null 
            );
            
        }
        return null;
    }
}