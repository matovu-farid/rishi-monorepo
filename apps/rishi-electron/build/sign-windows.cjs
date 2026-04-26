// Custom signing script for Azure Trusted Signing via electron-builder.
// electron-builder calls this with a configuration object containing the file path.
// Requires AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_TENANT_ID env vars.
const { execFileSync } = require('child_process')

exports.default = async function sign(configuration) {
  if (!process.env.AZURE_CLIENT_ID) {
    console.log('Skipping signing: AZURE_CLIENT_ID not set (local build)')
    return
  }

  const filePath = configuration.path
  console.log(`Signing ${filePath} with Azure Trusted Signing...`)

  execFileSync(
    'AzureSignTool',
    [
      'sign',
      '-kvu',
      'https://eus.codesigning.azure.net',
      '-kva',
      process.env.AZURE_CLIENT_ID,
      '-kvs',
      process.env.AZURE_CLIENT_SECRET,
      '-kvt',
      process.env.AZURE_TENANT_ID,
      '-kvc',
      'RishiPublicTrust',
      '-tr',
      'http://timestamp.acs.microsoft.com',
      '-td',
      'sha256',
      '-fd',
      'sha256',
      filePath
    ],
    { stdio: 'inherit' }
  )
}
