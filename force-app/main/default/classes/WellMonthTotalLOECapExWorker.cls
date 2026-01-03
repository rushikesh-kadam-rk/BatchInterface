public class WellMonthTotalLOECapExWorker implements IBatchWorker {

    // --- STATE VARIABLES ---
    private List<Id> recordIds;
    private Boolean shouldChainNextJob;
    private Boolean isCapExBatch;
    private Boolean shouldCallSelfBatch;
    private Integer runStage;
    
    // Filter criteria
    private Set<Id> wellIdSet;
    private Date startDate;
    private Date endDate;

    // --- CONSTRUCTORS ---

    // Primary Constructor used for internal chaining
    public WellMonthTotalLOECapExWorker(
        List<Id> recordIds,
        Boolean shouldChainNextJob,
        Boolean isCapExBatch,
        Boolean shouldCallSelfBatch,
        Integer runStage,
        Set<Id> wellIdSet,
        Date startDate,
        Date endDate
    ) {
        this.recordIds = recordIds;
        this.shouldChainNextJob = (shouldChainNextJob == null) ? true : shouldChainNextJob;
        this.isCapExBatch = (isCapExBatch == null) ? true : isCapExBatch; // Default true
        this.shouldCallSelfBatch = (shouldCallSelfBatch == null) ? true : shouldCallSelfBatch;
        this.runStage = (runStage == null) ? 1 : runStage;
        this.wellIdSet = wellIdSet;
        this.startDate = startDate;
        this.endDate = endDate;
    }

    // Default / External Entry Constructor
    public WellMonthTotalLOECapExWorker(
        Boolean shouldChainNextJob,
        Set<Id> wellIdSet,
        Date startDate,
        Date endDate,
        List<Id> recordIds
    ) {
        this(recordIds, shouldChainNextJob, true, true, 1, wellIdSet, startDate, endDate);
    }
    
    // Empty Constructor for Framework reflection/testing
    public WellMonthTotalLOECapExWorker() {
        this(null, true, true, true, 1, null, null, null);
    }

    // --- FRAMEWORK METHODS ---

    public String getBatchName() {
        // DYNAMIC NAME ALLOWS DIFFERENT BATCH SIZES IN METADATA
        // Create MDT records: 'Well_Cost_Calc_Stage1' (Size 50) and 'Well_Cost_Calc_Stage2' (Size 1)
        return 'Well_Cost_Calc_Stage' + runStage; 
    }

    public void setWhereClause(String whereClause) {
        // Optional implementation
    }

    public void setQueryParams(Map<String, Object> params) {
        // Optional implementation
    }

    // --- 1. DYNAMIC QUERY GENERATION ---
    public String getQuery() {
        String query;
        
        // Scenario A: Date/Set Based Filter
        if (wellIdSet != null && !wellIdSet.isEmpty() && startDate != null && endDate != null) {
            String dateFilter = 'Production_Start_Date__c >= ' + String.valueOf(startDate) + 
                              ' AND Production_Start_Date__c <= ' + String.valueOf(endDate);
            String idList = '(\'' + String.join(new List<Id>(wellIdSet), '\',\'') + '\')';
            
            return 'SELECT Id FROM Well__c WHERE Id IN ' + idList + ' AND ' + dateFilter;
        }

        // Scenario B: Cost Count / Stage Based Filter
        query = 'SELECT Id FROM Well__c WHERE Well_Cost_Count__c > 0 ';
        
        if (runStage == 1) {
            query += 'AND Well_Cost_Count__c <= 3000 ';
        } else if (runStage == 2) {
            query += 'AND Well_Cost_Count__c > 3000 ';
        }

        if (recordIds != null && !recordIds.isEmpty()) {
            String recIdList = '(\'' + String.join(recordIds, '\',\'') + '\')';
            query += 'AND Id IN ' + recIdList;
        }
        
        return query;
    }

    // --- 2. EXECUTE LOGIC ---
    public void processRecords(List<SObject> scope) {
        List<Well__c> wellScope = (List<Well__c>) scope;
        System.debug('Executing batch for scope size: ' + wellScope.size());
        
        Set<Id> wellIds = new Set<Id>();
        for (Well__c well : wellScope) {
            wellIds.add(well.Id);
        }

        Map<Id, Map<String, Decimal>> wellToTotalLOECapExCost = new Map<Id, Map<String, Decimal>>();
        String currentWellCostTypeAdjusted = isCapExBatch ? 'CapEx' : 'LOE';

        // NOTE: Aggregate queries in execute() can use bind variables safely
        List<AggregateResult> arList = [
            SELECT Well__c wellId, Well_Cost_Type_Adjusted__c,
                   CALENDAR_YEAR(Production_Period_End_Date__c) year,
                   CALENDAR_MONTH(Production_Period_End_Date__c) month,
                   SUM(Cost_Amount__c) sumCostAmount
            FROM Well_Cost__c
            WHERE Well__c IN :wellIds
            AND Well_Cost_Type_Adjusted__c = :currentWellCostTypeAdjusted
            AND Well_Month__r.Run_DLRS_Accruals__c = TRUE
            GROUP BY Well__c, Well_Cost_Type_Adjusted__c,
                     CALENDAR_YEAR(Production_Period_End_Date__c),
                     CALENDAR_MONTH(Production_Period_End_Date__c)
        ];

        for (AggregateResult ar : arList) {
            Id wellId = (Id) ar.get('wellId');
            Decimal sumCostAmount = (Decimal) ar.get('sumCostAmount');
            String monthStartKey = calculateMonthStartKey(ar);

            if (!wellToTotalLOECapExCost.containsKey(wellId)) {
                wellToTotalLOECapExCost.put(wellId, new Map<String, Decimal>());
            }
            wellToTotalLOECapExCost.get(wellId).put(monthStartKey, sumCostAmount);
        }

        if (wellToTotalLOECapExCost.isEmpty()) return;

        List<Well_Month__c> recordsToUpdate = new List<Well_Month__c>();
        List<Well_Month__c> wellMonths = [
            SELECT Id, Well__c, Well_Month_Date__c, LOE_Adjusted_Op_Reported__c, CapEx_Adjusted_Op_Reported__c
            FROM Well_Month__c
            WHERE Well__c IN :wellToTotalLOECapExCost.keySet()
            AND Run_DLRS_Accruals__c = TRUE
        ];

        for (Well_Month__c wm : wellMonths) {
            Date monthStart = Date.newInstance(wm.Well_Month_Date__c.year(), wm.Well_Month_Date__c.month(), 1);
            Map<String, Decimal> costTypeMonthMap = wellToTotalLOECapExCost.get(wm.Well__c);
            
            String capExKey = 'CapEx-' + monthStart.format();
            String loeKey = 'LOE-' + monthStart.format();

            if (costTypeMonthMap != null) {
                Decimal sumCapEx = costTypeMonthMap.get(capExKey);
                Decimal sumLOE = costTypeMonthMap.get(loeKey);
                Boolean changed = false;

                if (sumCapEx != null && wm.CapEx_Adjusted_Op_Reported__c != sumCapEx) {
                    wm.CapEx_Adjusted_Op_Reported__c = sumCapEx;
                    changed = true;
                }
                if (sumLOE != null && wm.LOE_Adjusted_Op_Reported__c != sumLOE) {
                    wm.LOE_Adjusted_Op_Reported__c = sumLOE;
                    changed = true;
                }
                if (changed) recordsToUpdate.add(wm);
            }
        }

        if (!recordsToUpdate.isEmpty()) {
            update recordsToUpdate;
        }
    }

    // --- 3. FINISH LOGIC ---
    public void onFinish(Database.BatchableContext bc) {
        System.debug('Stage ' + runStage + ' of ' + (isCapExBatch ? 'CapEx' : 'LOE') + ' completed.');
    }

    // --- 4. CHAINING LOGIC (STATE MACHINE) ---
    public IBatchWorker getNextWorker() {
        // State Machine: CapEx(1) -> CapEx(2) -> LOE(1) -> LOE(2) -> Next Job
        
        if (shouldCallSelfBatch) {
            if (isCapExBatch) {
                if (runStage == 1) {
                    // Move to CapEx Stage 2
                    return new WellMonthTotalLOECapExWorker(
                        recordIds, shouldChainNextJob, true, true, 2, wellIdSet, startDate, endDate
                    );
                } else if (runStage == 2) {
                    // Move to LOE Stage 1
                    return new WellMonthTotalLOECapExWorker(
                        recordIds, shouldChainNextJob, false, true, 1, wellIdSet, startDate, endDate
                    );
                }
            } else {
                // isCapExBatch = false (LOE)
                if (runStage == 1) {
                    // Move to LOE Stage 2
                    return new WellMonthTotalLOECapExWorker(
                        recordIds, shouldChainNextJob, false, false, 2, wellIdSet, startDate, endDate
                    );
                }
            }
        }

        // If cycle complete, trigger external job
        if (shouldChainNextJob) {
            return new WellMoGrossUniqueDecimalVolumeWorker(
                shouldChainNextJob, wellIdSet, startDate, endDate
            );
        }

        return null;
    }

    // --- HELPER ---
    private String calculateMonthStartKey(AggregateResult ar) {
        Integer year = ar != null ? (Integer) ar.get('year') : 2025;
        Integer month = ar != null ? (Integer) ar.get('month') : 5;
        String wellCostType = ar != null ? (String) ar.get('Well_Cost_Type_Adjusted__c') : 'LOE';
        return wellCostType + '-' + Date.newInstance(year, month, 1).format();
    }
}