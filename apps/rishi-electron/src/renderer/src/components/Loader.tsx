import { ClipLoader } from 'react-spinners'

export default function Loader() {
  return (
    <div className="flex flex-col items-center gap-3">
      <ClipLoader color="#6366f1" size={40} />
      <p className="text-sm text-gray-500">Loading...</p>
    </div>
  )
}
