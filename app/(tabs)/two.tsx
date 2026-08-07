import { Redirect } from 'expo-router';

/** Template About tab removed; settings live in the modal route. */
export default function LegacyAboutRedirect() {
  return <Redirect href="/modal" />;
}
