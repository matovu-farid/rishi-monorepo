import z, { success } from "zod";
import { Context, Effect } from "effect";
import {
  AppStoreServerAPIClient,
  Environment,
  SendTestNotificationResponse,
  SignedDataVerifier,
} from "../app-store-server-library-node";

async function parseR2TextFiles<T>(
  fileName: string,

  schema: z.ZodTypeAny<T>,
  bucket: R2Bucket,
) {
  const file = await bucket.get(fileName);
  if (!file) {
    throw new Error(`File not found in R2: ${fileName}`);
  }
  const data = await file.text();
  console.log({ data });
  const result = schema.parse(data);
  return result;
}
async function parseR2JsonFiles<T>(
  fileName: string,

  schema: z.ZodTypeAny<T>,
  bucket: R2Bucket,
) {
  const file = await bucket.get(fileName);
  if (!file) {
    throw new Error(`File not found in R2: ${fileName}`);
  }
  const data = await file?.json();
  console.log({ data });
  const result = schema.parse(data);
  return result;
}

export class AppleBucket extends Context.Tag("DatabaseService")<
  AppleBucket,
  R2Bucket
>() {}

const Data = {
  appKey: {
    fileName: "app-key.json",
    schema: z.object({
      "issuer-key": z.string(),
      "key-id": z.string(),
      "app-id": z.string(),
      "app-apple-id": z.number(),
    }),
  },
  subscriptionKey: {
    fileName: "SubscriptionKey.p8",
    schema: z.string(),
  },
};
const getClientEffect = Effect.gen(function* () {
  const bucket = yield* AppleBucket;

  const appKey = yield* Effect.tryPromise(() =>
    parseR2JsonFiles(Data.appKey.fileName, Data.appKey.schema, bucket),
  );

  const issuerId = appKey["issuer-key"];
  const keyId = appKey["key-id"];
  const bundleId = appKey["app-id"];
  const appAppleId = appKey["app-apple-id"];
  const encodedKey = yield* Effect.tryPromise(() =>
    parseR2TextFiles(
      Data.subscriptionKey.fileName,
      Data.subscriptionKey.schema,
      bucket,
    ),
  );

  const environment = Environment.SANDBOX;

  const client = new AppStoreServerAPIClient(
    encodedKey,
    keyId,
    issuerId,
    bundleId,
    environment,
  );

  const verifier = new SignedDataVerifier(environment, bundleId, appAppleId);

  return { client, bundleId, verifier };
});

export function createTestNotification() {
  return Effect.gen(function* () {
    const { client } = yield* getClientEffect;

    const response: SendTestNotificationResponse = yield* Effect.tryPromise({
      try: () => client.requestTestNotification(),
      catch(error) {
        throw error;
      },
    });
    return response;
  });
}
export function verifySignedTransaction(transactionId: string) {
  return Effect.gen(function* () {
    const { verifier, client } = yield* getClientEffect;

    const transaction = yield* Effect.tryPromise({
      try: async () => {
        await client.getTransactionInfo(transactionId)
      },
      catch: (error) => {
        console.log(error)
        error
      },
    });

    return transaction;
  });
}
