// import { embed, EmbedParam, Metadata, saveVectors, Vector } from "@/generated";
// import { Book, BookInsertable, db, PageDataInsertable } from "./kysley";

// async function hasSavedData(pageNumber: number, bookId: string) {
//   // if we have atleast one chink
//   const result = await db
//     .selectFrom("chunk_data")
//     .where("pageNumber", "=", pageNumber)
//     .where("bookId", "=", bookId)
//     .select("id")
//     .executeTakeFirst();

//   if (!result) return false;
//   return true;
// }

// export async function savePageDataMany(pageData: PageDataInsertable[]) {
//   if (pageData.length === 0) return;

//   await db
//     .insertInto("chunk_data")
//     .values(pageData)
//     .onConflict((oc) =>
//       oc.column("id").doUpdateSet({
//         data: (eb) => eb.ref("excluded.data"),
//       })
//     )
//     .execute();
// }

// export async function getAllPageDataByBookId(bookId: string) {
//   const result = await db
//     .selectFrom("chunk_data")
//     .selectAll()
//     .where("bookId", "=", bookId)
//     .orderBy("pageNumber", "asc")
//     .execute();

//   return result;
// }

// export async function saveBook(book: BookInsertable): Promise<Book> {
//   const result = await db
//     .insertInto("books")
//     .values({
//       author: book.author || "",
//       publisher: book.publisher || "",
//       filepath: book.filepath,
//       cover: book.cover,
//       version: book.version,
//       location: book.location,
//       kind: book.kind,
//       title: book.title || "",
//       cover_kind: book.cover_kind || "",
//     })
//     .onConflict((oc) => oc.column("id").doNothing())
//     .onConflict((oc) => oc.column("filepath").doNothing())
//     .returningAll()
//     .execute();

//   return result[0];
// }

// export async function getBook(id: number) {
//   const result = await db
//     .selectFrom("books")
//     .selectAll()
//     .where("id", "=", id)
//     .executeTakeFirst();
//   // Convert cover string back to number array if it's a string
//   if (result?.cover && typeof result.cover === "string") {
//     result.cover = JSON.parse(result.cover);
//   }
//   return result;
// }

// export async function getBooks() {
//   const result = await db.selectFrom("books").selectAll().execute();
//   result.forEach((book) => {
//     if (book.cover && typeof book.cover === "string") {
//       book.cover = JSON.parse(book.cover);
//     }
//   });
//   return result;
// }

// export async function deleteBook(id: number) {
//   await db.deleteFrom("books").where("id", "=", id).execute();
// }

// export async function updateBookCover(id: number, cover: number[]) {
//   await db.updateTable("books").set({ cover }).where("id", "=", id).execute();
// }

// export async function processJob(
//   pageNumber: number,
//   bookId: string,
//   pageData: PageDataInsertable[]
// ) {
//   try {
//     if (await hasSavedData(pageNumber, bookId)) {
//       return;
//     }
//     if (pageData.length === 0) {
//       return;
//     }

//     const embedParams: EmbedParam[] = pageData.map((item) => {
//       const metadata: Metadata = {
//         id: item.id,
//         pageNumber: pageNumber,
//         bookId: parseInt(bookId),
//       };
//       return {
//         text: item.data,
//         metadata,
//       };
//     });

//     // Save page data first, then embed
//     // This ensures data is in the database even if embedding fails
//     await savePageDataMany(pageData);

//     const embedResults = await embed({ embedparams: embedParams });

//     const vectorObjects = embedResults.map((result) => {
//       return {
//         id: result.metadata.id,
//         vector: result.embedding,
//         text: result.text,
//         metadata: result.metadata,
//       };
//     });
//     const vectors: Vector[] = vectorObjects.map((vector) => ({
//       id: vector.id,
//       vector: vector.vector,
//     }));

//     await saveVectors({
//       name: `${bookId}-vectordb`,
//       dim: vectorObjects[0].vector.length,
//       vectors,
//     });
//   } catch (error) {
//     console.error(`>>> Error in createPage for page ${pageNumber}:`, error);
//     throw error;
//   }
// }

// export async function hasSavedEpubData(bookId: string) {
//   const result = await db
//     .selectFrom("chunk_data")
//     .where("bookId", "=", bookId)
//     .select("id")
//     .executeTakeFirst();

//   return !!result;
// }

// export async function updateBookLocation(bookId: string, location: string) {
//   // await updateBook({ id: bookId, location: location }, store);
//   await db
//     .updateTable("books")
//     .set({ location })
//     .where("id", "=", parseInt(bookId))
//     .execute();
// }
// export async function getTextFromVectorId(vectorId: number) : Promise<string> {
//   const res = await db
//     .selectFrom("chunk_data")
//     .where("id", "=", vectorId)
//     .select("data")
//     .executeTakeFirst();
//   return res?.data || "";
// }
