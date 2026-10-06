/** The small portion of jatos.js used by this experiment (JATOS 3.11). */
export interface JatosApi {
  onLoad(callback: () => void): void;
  urlQueryParameters: Record<string, string | undefined>;
  studyId?: number;
  componentId?: number;
  batchId?: number;
  workerId?: number;
  studyResultId?: number;
  componentResultId?: number;
  submitResultData(data: string): Promise<unknown>;
  endStudyWithoutRedirect(): Promise<unknown>;
}

declare global {
  interface Window {
    jatos?: JatosApi;
  }
}
