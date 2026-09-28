import type {
  CardRecord,
  ClientMessage,
  CreateInvitationRequest,
  GroupState,
  HistoryResponse,
  JoinRequest,
  LocationEvent,
  PublishResponse,
  PutCardRequest,
  ServerInfo,
  ServerMessage,
} from "@openlocate/protocol";

export interface HistoryQuery {
  /** Return events with a server sequence number greater than this (cursor). */
  after?: number;
  /** Only events from this device. */
  from?: string;
  limit?: number;
}

export interface Subscription {
  send(msg: ClientMessage): void;
  close(): void;
  /** Resolves when the socket is closed, for whatever reason. */
  closed: Promise<void>;
}

/**
 * Everything the app needs from a backend. The app talks only to this interface, so a backend
 * that doesn't speak the OpenLocate HTTP protocol (Firebase, Supabase, ...) can be plugged in
 * by implementing it. Every payload crossing it is already end-to-end encrypted.
 */
export interface BackendProvider {
  info(): Promise<ServerInfo>;
  createGroup(groupId: string): Promise<GroupState>;
  getGroup(groupId: string): Promise<GroupState>;
  createInvitation(groupId: string, req: CreateInvitationRequest): Promise<void>;
  revokeInvitation(groupId: string, inviteId: string): Promise<void>;
  joinGroup(groupId: string, req: JoinRequest): Promise<GroupState>;
  /** Leave (own device id) or, as an admin, remove someone. */
  removeMember(groupId: string, deviceId: string): Promise<void>;
  putCard(groupId: string, to: string, req: PutCardRequest): Promise<void>;
  /** Cards addressed to this device. */
  getCards(groupId: string): Promise<CardRecord[]>;
  publishLocation(groupId: string, events: LocationEvent[]): Promise<PublishResponse>;
  getHistory(groupId: string, query?: HistoryQuery): Promise<HistoryResponse>;
  /** Delete this device's stored history, optionally only events expiring before `expiresBefore`. */
  deleteHistory(groupId: string, expiresBefore?: number): Promise<void>;
  subscribe(groupId: string, onMessage: (msg: ServerMessage) => void): Promise<Subscription>;
}
