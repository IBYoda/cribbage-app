import Link from "next/link";
import { CardRoomFrame } from "@/components/brand/CardRoomFrame";

// THE 404 PAGE: any URL that isn't a page, in the card-room look, with one
// way out -- home.
export default function NotFound() {
  return (
    <CardRoomFrame title="Wrong room" backHome={false}>
      <p>No such table in this room. The page you were after isn&apos;t here.</p>
      <Link href="/" className="peg-btn peg-btn--brass">
        Back home
      </Link>
    </CardRoomFrame>
  );
}
