public class WellWecimalRollupWorker implements IBatchWorker {

    // --- STATE VARIABLES ---
    private Boolean shouldChainNextJob;
    private Set<Id> wellIdSet;
    private Date startDate;
    private Date endDate;
    private List<RollupDefinition__mdt> rollupDefinitions;

    // --- CONSTRUCTORS ---

    public WellWecimalRollupWorker(
        Boolean shouldChainNextJob,
        Set<Id> wellIdSet,
        Date startDate,
        Date endDate
    ) {
        this.shouldChainNextJob = (shouldChainNextJob == null) ? true : shouldChainNextJob;
        this.wellIdSet = wellIdSet;
        this.startDate = startDate;
        this.endDate = endDate;
        
        initializeConfig();
    }

    public WellWecimalRollupWorker() {
        this(true, null, null, null);
    }

    private void initializeConfig() {
        this.rollupDefinitions = [
            SELECT Parent_Object__c, Parent_Field_To_Update__c, Child_Object__c, 
                   Field_To_Aggregate__c, Aggregate_Function__c, Child_Filter__c, 
                   Batch_Size__c, Process_Group__c, Rollup_Type__c, Active__c
            FROM RollupDefinition__mdt
            WHERE Process_Group__c = 'NRI Static' AND Active__c = TRUE
        ];
    }

    // --- FRAMEWORK METHODS ---

    public String getBatchName() {
        // Create MDT record for this. Recommended Batch Size: 300
        return 'Well_Wecimal_NRI_Rollup'; 
    }

    public void setWhereClause(String whereClause) {}
    public void setQueryParams(Map<String, Object> params) {}

    // --- 1. DYNAMIC QUERY GENERATION ---
    public String getQuery() {
        // Scenario A: Specific Wells & Dates
        if (wellIdSet != null && !wellIdSet.isEmpty() && startDate != null && endDate != null) {
            String idList = '(\'' + String.join(new List<Id>(wellIdSet), '\',\'') + '\')';
            String dateFilter = 'Production_Start_Date__c >= ' + String.valueOf(startDate) + 
                              ' AND Production_Start_Date__c <= ' + String.valueOf(endDate);
            
            return 'SELECT Id, Name FROM Well__c WHERE Id IN ' + idList + ' AND ' + dateFilter;
        }

        // Scenario B: Full Run
        return 'SELECT Id, Name FROM Well__c WHERE Well_Decimal_Count__c > 0';
    }

    // --- 2. EXECUTE LOGIC ---
    public void processRecords(List<SObject> scope) {
        List<Well__c> wellScope = (List<Well__c>) scope;
        if (wellScope.isEmpty() || rollupDefinitions.isEmpty()) {
            System.debug('No records to process.');
            return;
        }

        Set<Id> parentIds = new Set<Id>();
        for (Well__c well : wellScope) {
            parentIds.add(well.Id);
        }

        Map<String, Decimal> aggMap = new Map<String, Decimal>();

        // Iterate Config to build Aggregates
        for (RollupDefinition__mdt def : rollupDefinitions) {
            String query = 'SELECT ' + def.Aggregate_Function__c + '(' + def.Field_To_Aggregate__c + ') aggVal, ' + 
                           def.Parent_Object__c + ' FROM ' + def.Child_Object__c + 
                           ' WHERE ' + def.Parent_Object__c + ' IN :parentIds';

            if (String.isNotBlank(def.Child_Filter__c)) {
                query += ' AND ' + def.Child_Filter__c;
            }

            query += ' GROUP BY ' + def.Parent_Object__c;

            // Execute Query (Safe to use bind :parentIds here)
            for (SObject record : Database.query(query)) {
                Id parentId = (Id) record.get(def.Parent_Object__c);
                Decimal value = (Decimal) record.get('aggVal');
                if (value == null) value = 0;

                String key = parentId + '|' + def.Parent_Field_To_Update__c;
                aggMap.put(key, aggMap.containsKey(key) ? aggMap.get(key) + value : value);
            }
        }

        // Apply Updates
        for (Well__c well : wellScope) {
            for (RollupDefinition__mdt def : rollupDefinitions) {
                String key = well.Id + '|' + def.Parent_Field_To_Update__c;
                
                if (aggMap.containsKey(key)) {
                    well.put(def.Parent_Field_To_Update__c, aggMap.get(key));
                } else {
                    // CRITICAL: Default to 0 if no children found
                    well.put(def.Parent_Field_To_Update__c, 0);
                }
            }
        }

        update wellScope;
    }

    // --- 3. FINISH LOGIC (Chatter Post) ---
    public void onFinish(Database.BatchableContext bc) {
        System.debug('Update NRI completed. Chain Finished.');

        // Updated Logic: Get the Creator of THIS specific job run
        if (bc != null) {
            List<AsyncApexJob> job = [SELECT CreatedById FROM AsyncApexJob WHERE Id = :bc.getJobId()];
            if (!job.isEmpty()) {
                createChatterPost(job[0].CreatedById);
            }
        }
    }

    // --- 4. CHAINING LOGIC (End of Chain) ---
    public IBatchWorker getNextWorker() {
        return null; 
    }

    // --- HELPER: Chatter Post ---
    private void createChatterPost(Id userToMentionId) {
        Id userId = UserInfo.getUserId();
        String postText = ' All the batch classes have been finished.';
        
        try {
            ConnectApi.MentionSegmentInput mentionSegmentInput = new ConnectApi.MentionSegmentInput();
            ConnectApi.FeedItemInput feedItemInput = new ConnectApi.FeedItemInput();
            ConnectApi.MessageBodyInput messageBodyInput = new ConnectApi.MessageBodyInput();
            ConnectApi.TextSegmentInput textSegmentInput = new ConnectApi.TextSegmentInput();

            messageBodyInput.messageSegments = new List<ConnectApi.MessageSegmentInput>();
            mentionSegmentInput.id = userToMentionId;
            messageBodyInput.messageSegments.add(mentionSegmentInput);
            textSegmentInput.text = postText;
            messageBodyInput.messageSegments.add(textSegmentInput);

            feedItemInput.body = messageBodyInput;
            feedItemInput.feedElementType = ConnectApi.FeedElementType.FeedItem;
            feedItemInput.subjectId = userId;

            // Only run if ConnectApi is available (avoids test failures in some orgs)
            if(!Test.isRunningTest()) {
                ConnectApi.FeedElement feedElement = ConnectApi.ChatterFeeds.postFeedElement(
                    Network.getNetworkId(),
                    feedItemInput
                );
            }
        } catch (Exception ex) {
            System.debug('Create Chatter Post Exception ' + ex.getMessage());
        }
    }
}