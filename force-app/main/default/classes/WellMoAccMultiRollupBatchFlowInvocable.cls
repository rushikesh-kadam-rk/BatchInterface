public with sharing class WellMoAccMultiRollupBatchFlowInvocable {
  @InvocableMethod(
    label='Run WellMonthAccrualsMultiRollupBatch Batch For Specific Wells'
    description='Runs the WellMonthAccrualsMultiRollupBatch with an chaining flag.'
  )
  public static void runTotalLOWCapExBatch(List<BatchRequest> requests) {
    for (BatchRequest req : requests) {
      Boolean shouldChain = (req.shouldChainNextJob == null)
        ? false
        : req.shouldChainNextJob;
      List<Id> recordIds = req.wellIds != null ? req.wellIds : null;
      Set<id> wellIds = new Set<Id>(recordIds);
      Database.executeBatch(
        new WellMonthAccrualsMultiRollupBatch(
          shouldChain,
          wellIds,
          req.startDate,
          req.endDate,
          req.revenueEndDate
        ),
        50
      );
    }
  }

  public class BatchRequest {
    @InvocableVariable(required=true label='Should Chain Next Job')
    public Boolean shouldChainNextJob;
    @InvocableVariable(required=true label='Well Record Ids')
    public List<Id> wellIds;
    @InvocableVariable(required=true label='Start Date')
    public Date startDate;
    @InvocableVariable(required=true label='End Date')
    public Date endDate;
    @InvocableVariable(required=true label='Revenue End Date')
    public Date revenueEndDate;
  }
}
