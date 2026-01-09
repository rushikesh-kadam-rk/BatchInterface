public with sharing class WellWecimalRollupFlowInvocable {

    @InvocableMethod(label='Run WellWecimal Rollup Batch' description='Runs the WellWecimalRollupBatch with an optional chaining flag.')
    public static void runWecimalBatch(List<BatchRequest> requests) {
        for (BatchRequest req : requests) {
            // Default to true if shouldChainNextJob is null
            Boolean shouldChain = (req.shouldChainNextJob == null) ? true : req.shouldChainNextJob;
            
            Database.executeBatch(new WellWecimalRollupBatch(shouldChain));
        }
    }

    public class BatchRequest {
        @InvocableVariable(required=false label='Should Chain Next Job' description='Set to False to run standalone, True for chained execution')
        public Boolean shouldChainNextJob;
    }
}