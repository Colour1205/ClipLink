import localUnitTest from './LocalUnit.test';
import lineFramerTest from './LineFramer.test';
import fileNamesTest from './FileNames.test';
import identityKeyTest from './IdentityKey.test';
import chunkOrderTest from './ChunkOrder.test';
import nonceKeyTest from './NonceKey.test';
import beaconTest from './Beacon.test';
import messageRelayTest from './MessageRelay.test';
import historyBatchTest from './HistoryBatch.test';
import syncedRowsTest from './SyncedRows.test';

export default function testsuite() {
  localUnitTest();
  lineFramerTest();
  fileNamesTest();
  identityKeyTest();
  chunkOrderTest();
  nonceKeyTest();
  beaconTest();
  messageRelayTest();
  historyBatchTest();
  syncedRowsTest();
}