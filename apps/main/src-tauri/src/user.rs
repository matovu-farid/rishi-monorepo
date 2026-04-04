// const user: {
//     readonly id: string;
//     readonly passwordEnabled: boolean;
//     readonly totpEnabled: boolean;
//     readonly backupCodeEnabled: boolean;
//     readonly twoFactorEnabled: boolean;
//     readonly banned: boolean;
//     readonly locked: boolean;
//     readonly createdAt: number;
//     readonly updatedAt: number;
//     readonly imageUrl: string;
//     readonly hasImage: boolean;
//     readonly primaryEmailAddressId: string | null;
//     readonly primaryPhoneNumberId: string | null;
//     readonly primaryWeb3WalletId: string | null;
//     readonly lastSignInAt: number | null;
//     readonly externalId: string | null;
//     readonly username: string | null;
//     readonly firstName: string | null;
//     readonly lastName: string | null;
//     readonly publicMetadata: UserPublicMetadata;
//     readonly privateMetadata: UserPrivateMetadata;
//     readonly unsafeMetadata: UserUnsafeMetadata;
//     readonly emailAddresses: EmailAddress[];
//     readonly phoneNumbers: PhoneNumber[];
//     readonly web3Wallets: Web3Wallet[];
//     readonly externalAccounts: ExternalAccount[];
//     readonly samlAccounts: SamlAccount[];
//     readonly lastActiveAt: number | null;
//     readonly createOrganizationEnabled: boolean;
//     readonly createOrganizationsLimit: number | null;
//     readonly deleteSelfEnabled: boolean;
//     readonly legalAcceptedAt: number | null;
//     readonly locale: string | null;
//     raw: UserJSON | null;
//     primaryEmailAddress: EmailAddress | null;
//     primaryPhoneNumber: PhoneNumber | null;
//     primaryWeb3Wallet: Web3Wallet | null;
//     fullName: string | null;
// }

use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct User {
    id: String,
    first_name: Option<String>,
    last_name: Option<String>,
    full_name: Option<String>,
    username: Option<String>,
    image_url: Option<String>,
    has_image: bool,
    last_sign_in_at: Option<i64>,
    external_id: Option<String>,
}
