export interface DocumentRendition {
  getCurrentText(): Promise<string>;
  highlight(location: string): void;
  goToLocation(location: string): void;
  getNextText(): Promise<string>;
}
