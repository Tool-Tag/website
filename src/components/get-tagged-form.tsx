"use client";

import { useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import {
  PICKUP_FEE,
  PICKUP_REQUEST_DISCLAIMER,
  emptyGetTaggedRequest,
  emptyItem,
  emptyMark,
  getTaggedRequestSchema,
  type GetTaggedItem,
  type GetTaggedMark,
  type GetTaggedRequest,
} from "@/lib/public/get-tagged";

const SESSION_KEY = "tooltag-public-request-v2";

type GetTaggedFormProps = {
  modal?: boolean;
  onSuccess?: (reference: string) => void;
};

export function GetTaggedForm({
  modal = false,
  onSuccess,
}: GetTaggedFormProps = {}) {
  const [request, setRequest] = useState<GetTaggedRequest>(emptyGetTaggedRequest);
  const [token, setToken] = useState("");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState("");
  const [refreshNeeded, setRefreshNeeded] = useState(false);
  const honeypot = useRef<HTMLInputElement>(null);
  const submitting = useRef(false);
  const router = useRouter();
  const requestRef = useRef(request);

  useEffect(() => {
    requestRef.current = request;
  }, [request]);

  async function refreshSession() {
    try {
      const response = await fetch("/api/get-tagged", { cache: "no-store" });
      const body = await response.json();
      if (!response.ok) throw new Error(body.error);
      setToken(body.token);
      setError("");
      setRefreshNeeded(false);
      try {
        sessionStorage.setItem(
          SESSION_KEY,
          JSON.stringify({ request: requestRef.current, token: body.token }),
        );
      } catch {}
    } catch (err) {
      setError(err instanceof Error ? err.message : "Unable to open the form. Please try again.");
    }
  }

  useEffect(() => {
    let active = true;
    Promise.resolve().then(() => {
      if (!active) return;
      try {
        const saved = JSON.parse(sessionStorage.getItem(SESSION_KEY) || "null");
        if (saved?.request) setRequest(saved.request);
        if (saved?.token) {
          setToken(saved.token);
          return;
        }
      } catch {}
      refreshSession();
    });
    return () => {
      active = false;
    };
  }, []);

  useEffect(() => {
    if (!token) return;
    try {
      sessionStorage.setItem(SESSION_KEY, JSON.stringify({ request, token }));
    } catch {}
  }, [request, token]);

  function updateItem(index: number, patch: Partial<GetTaggedItem>) {
    setRequest((current) => ({
      ...current,
      items: current.items.map((item, itemIndex) =>
        itemIndex === index ? { ...item, ...patch } : item,
      ),
    }));
  }

  function updateMark(
    itemIndex: number,
    markIndex: number,
    patch: Partial<GetTaggedMark>,
  ) {
    setRequest((current) => ({
      ...current,
      items: current.items.map((item, currentItemIndex) =>
        currentItemIndex === itemIndex
          ? {
              ...item,
              marks: item.marks.map((mark, currentMarkIndex) =>
                currentMarkIndex === markIndex ? { ...mark, ...patch } : mark,
              ),
            }
          : item,
      ),
    }));
  }

  async function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (submitting.current) return;

    setError("");
    const parsed = getTaggedRequestSchema.safeParse(request);
    if (!parsed.success) {
      setError(parsed.error.issues[0]?.message ?? "Review the form and try again.");
      return;
    }

    submitting.current = true;
    setPending(true);

    try {
      const response = await fetch("/api/get-tagged", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          token,
          website: honeypot.current?.value || "",
          request: parsed.data,
        }),
      });
      const body = await response.json();

      if (!response.ok) {
        setRefreshNeeded(Boolean(body.refresh));
        throw new Error(body.error || "Unable to submit. Please try again.");
      }

      try {
        sessionStorage.removeItem(SESSION_KEY);
      } catch {}

      const reference = String(body.reference || "");
      if (onSuccess) {
        setPending(false);
        submitting.current = false;
        onSuccess(reference);
        return;
      }

      router.push(
        "/get-tagged/thanks?reference=" + encodeURIComponent(reference),
      );
    } catch (err) {
      setError(
        err instanceof Error
          ? err.message
          : "We could not confirm receipt. Try again with the same form; it will not create a duplicate.",
      );
      setPending(false);
      submitting.current = false;
    }
  }

  return (
    <form
      onSubmit={submit}
      className={modal ? "intake-form intake-form-modal" : "intake-form"}
    >
      <fieldset disabled={pending} className="intake-section">
        <legend>1. Your details</legend>
        <div className="intake-grid">
          <label>
            Full name
            <input
              required
              maxLength={160}
              autoComplete="name"
              value={request.contact.name}
              onChange={(event) =>
                setRequest((current) => ({
                  ...current,
                  contact: { ...current.contact, name: event.target.value },
                }))
              }
            />
          </label>

          <label>
            Email
            <input
              required
              type="email"
              maxLength={254}
              autoComplete="email"
              value={request.contact.email}
              onChange={(event) =>
                setRequest((current) => ({
                  ...current,
                  contact: { ...current.contact, email: event.target.value },
                }))
              }
            />
          </label>

          <label>
            Phone
            <input
              required
              type="tel"
              maxLength={40}
              autoComplete="tel"
              value={request.contact.phone}
              onChange={(event) =>
                setRequest((current) => ({
                  ...current,
                  contact: { ...current.contact, phone: event.target.value },
                }))
              }
            />
          </label>
        </div>

        <details>
          <summary>Company details (optional)</summary>
          <div className="intake-grid">
            <label>
              Company name
              <input
                maxLength={160}
                autoComplete="organization"
                value={request.contact.company_name}
                onChange={(event) =>
                  setRequest((current) => ({
                    ...current,
                    contact: {
                      ...current.contact,
                      company_name: event.target.value,
                    },
                  }))
                }
              />
            </label>

            <label>
              Company email
              <input
                type="email"
                maxLength={254}
                value={request.contact.company_email}
                onChange={(event) =>
                  setRequest((current) => ({
                    ...current,
                    contact: {
                      ...current.contact,
                      company_email: event.target.value,
                    },
                  }))
                }
              />
            </label>

            <label>
              Company phone
              <input
                type="tel"
                maxLength={40}
                value={request.contact.company_phone}
                onChange={(event) =>
                  setRequest((current) => ({
                    ...current,
                    contact: {
                      ...current.contact,
                      company_phone: event.target.value,
                    },
                  }))
                }
              />
            </label>
          </div>
        </details>
      </fieldset>

      <fieldset disabled={pending} className="intake-section">
        <legend>2. What would you like engraved?</legend>

        {request.items.map((item, itemIndex) => (
          <section
            className="intake-item"
            aria-label={"Item " + (itemIndex + 1)}
            key={itemIndex}
          >
            <div className="intake-heading">
              <h2>Item {itemIndex + 1}</h2>
              {request.items.length > 1 && (
                <button
                  type="button"
                  className="secondary"
                  onClick={() =>
                    setRequest((current) => ({
                      ...current,
                      items: current.items.filter(
                        (_, index) => index !== itemIndex,
                      ),
                    }))
                  }
                >
                  Remove item {itemIndex + 1}
                </button>
              )}
            </div>

            <div className="intake-grid">
              <label>
                Item / tool / part
                <input
                  required
                  maxLength={160}
                  placeholder="Battery, drill, toolbox…"
                  value={item.article}
                  onChange={(event) =>
                    updateItem(itemIndex, { article: event.target.value })
                  }
                />
              </label>

              <label>
                Brand
                <input
                  required
                  maxLength={160}
                  placeholder={'Brand or "Not sure"'}
                  value={item.brand}
                  onChange={(event) =>
                    updateItem(itemIndex, { brand: event.target.value })
                  }
                />
              </label>

              <label>
                Model (optional)
                <input
                  maxLength={160}
                  value={item.model}
                  onChange={(event) =>
                    updateItem(itemIndex, { model: event.target.value })
                  }
                />
              </label>

              <label>
                Quantity
                <input
                  required
                  type="number"
                  min="1"
                  max="1000"
                  step="1"
                  inputMode="numeric"
                  value={item.quantity || ""}
                  onChange={(event) =>
                    updateItem(itemIndex, {
                      quantity: Number(event.target.value),
                    })
                  }
                />
              </label>
            </div>

            <p className="muted">
              {item.marks.length} engraving
              {item.marks.length === 1 ? "" : "s"} per piece. Add a separate
              item if the pieces need different designs.
            </p>

            {item.marks.map((mark, markIndex) => (
              <fieldset className="intake-mark" key={markIndex}>
                <legend>Engraving {markIndex + 1}</legend>

                <div className="intake-grid">
                  <label>
                    Location
                    <input
                      required
                      maxLength={160}
                      placeholder="Left side, lid, handle…"
                      value={mark.location}
                      onChange={(event) =>
                        updateMark(itemIndex, markIndex, {
                          location: event.target.value,
                        })
                      }
                    />
                  </label>

                  <label>
                    Type
                    <select
                      value={mark.type}
                      onChange={(event) =>
                        updateMark(itemIndex, markIndex, {
                          type: event.target.value as GetTaggedMark["type"],
                        })
                      }
                    >
                      <option value="Text">Text</option>
                      <option value="Image / Logo">Logo / Image</option>
                    </select>
                  </label>
                </div>

                {mark.type === "Text" ? (
                  <label>
                    Text to engrave
                    <textarea
                      required
                      maxLength={1000}
                      rows={2}
                      value={mark.text}
                      onChange={(event) =>
                        updateMark(itemIndex, markIndex, {
                          text: event.target.value,
                        })
                      }
                    />
                  </label>
                ) : (
                  <>
                    <label>
                      Describe your logo / image
                      <textarea
                        required
                        maxLength={1000}
                        rows={2}
                        value={mark.description}
                        onChange={(event) =>
                          updateMark(itemIndex, markIndex, {
                            description: event.target.value,
                          })
                        }
                      />
                    </label>

                    <label>
                      Reference link (optional)
                      <input
                        type="url"
                        maxLength={2000}
                        placeholder="https://…"
                        value={mark.url}
                        onChange={(event) =>
                          updateMark(itemIndex, markIndex, {
                            url: event.target.value,
                          })
                        }
                      />
                    </label>

                    <p className="muted">
                      No file needed yet. We will arrange artwork with you before
                      preparing your Quote.
                    </p>
                  </>
                )}

                <label className="checkbox">
                  <input
                    type="checkbox"
                    checked={mark.paint_fill}
                    onChange={(event) =>
                      updateMark(itemIndex, markIndex, {
                        paint_fill: event.target.checked,
                      })
                    }
                  />
                  Add paint fill
                </label>

                {mark.paint_fill && (
                  <label>
                    Color(s) / paint instructions
                    <input
                      required
                      maxLength={160}
                      placeholder={'White, red and black, or "Not sure"'}
                      value={mark.color}
                      onChange={(event) =>
                        updateMark(itemIndex, markIndex, {
                          color: event.target.value,
                        })
                      }
                    />
                  </label>
                )}

                {item.marks.length > 1 && (
                  <button
                    type="button"
                    className="secondary"
                    onClick={() =>
                      updateItem(itemIndex, {
                        marks: item.marks.filter(
                          (_, index) => index !== markIndex,
                        ),
                      })
                    }
                  >
                    Remove engraving {markIndex + 1}
                  </button>
                )}
              </fieldset>
            ))}

            <button
              type="button"
              className="secondary"
              disabled={item.marks.length >= 20}
              onClick={() =>
                updateItem(itemIndex, {
                  marks: [...item.marks, emptyMark()],
                })
              }
            >
              + Add engraving
            </button>

            <details>
              <summary>Approximate size & item notes (optional)</summary>
              <div className="intake-grid">
                <label>
                  Width (mm)
                  <input
                    type="number"
                    min="0.01"
                    max="10000"
                    step="0.01"
                    inputMode="decimal"
                    value={item.width_mm}
                    onChange={(event) =>
                      updateItem(itemIndex, { width_mm: event.target.value })
                    }
                  />
                </label>

                <label>
                  Height (mm)
                  <input
                    type="number"
                    min="0.01"
                    max="10000"
                    step="0.01"
                    inputMode="decimal"
                    value={item.height_mm}
                    onChange={(event) =>
                      updateItem(itemIndex, { height_mm: event.target.value })
                    }
                  />
                </label>
              </div>

              <label>
                Item notes
                <textarea
                  maxLength={2000}
                  rows={2}
                  value={item.notes}
                  onChange={(event) =>
                    updateItem(itemIndex, { notes: event.target.value })
                  }
                />
              </label>
            </details>
          </section>
        ))}

        <button
          type="button"
          className="secondary"
          disabled={request.items.length >= 20}
          onClick={() =>
            setRequest((current) => ({
              ...current,
              items: [...current.items, emptyItem()],
            }))
          }
        >
          + Add item
        </button>
      </fieldset>

      <fieldset disabled={pending} className="intake-section">
        <legend>3. Service & notes</legend>

        <label>
          Preferred service
          <select
            value={request.service.method}
            onChange={(event) =>
              setRequest((current) => ({
                ...current,
                service: {
                  ...current.service,
                  method: event.target.value as GetTaggedRequest["service"]["method"],
                  address:
                    event.target.value === "Pickup"
                      ? current.service.address
                      : "",
                },
              }))
            }
          >
            <option value="Drop-off">Drop-off</option>
            <option value="Pickup">Pickup & Delivery</option>
            <option value="On-site" disabled>
              On-site — temporarily unavailable
            </option>
            <option value="Not sure">Not sure / discuss with ToolTag</option>
          </select>
        </label>

        {request.service.method === "Pickup" && (
          <>
            <label>
              Pickup address
              <input
                required
                maxLength={500}
                autoComplete="street-address"
                value={request.service.address}
                onChange={(event) =>
                  setRequest((current) => ({
                    ...current,
                    service: {
                      ...current.service,
                      address: event.target.value,
                    },
                  }))
                }
              />
            </label>

            <div className="notice pickup-request-terms">
              <strong>Pickup & Delivery</strong>
              <p>
                A {"$" + PICKUP_FEE.toFixed(2)} logistics fee applies and must be
                paid and confirmed before the requested Pickup is confirmed.
              </p>
              {PICKUP_REQUEST_DISCLAIMER.split("\n\n").map(
                (paragraph, index) => (
                  <p key={index}>{paragraph}</p>
                ),
              )}
            </div>
          </>
        )}

        <label>
          Anything else we should know? (optional)
          <textarea
            maxLength={2000}
            rows={3}
            value={request.notes}
            onChange={(event) =>
              setRequest((current) => ({
                ...current,
                notes: event.target.value,
              }))
            }
          />
        </label>

      </fieldset>

      <div className="intake-honeypot" aria-hidden="true">
        <label>
          Leave this field empty
          <input
            ref={honeypot}
            name="website"
            tabIndex={-1}
            autoComplete="off"
          />
        </label>
      </div>

      <p className="muted">
        We will review your request before creating a Quote. Submitting this
        request does not approve a price, authorize work, or create a Job.
      </p>

      {error && (
        <div role="alert" className="notice error">
          <p>{error}</p>
          {(!token || refreshNeeded) && (
            <button
              type="button"
              className="secondary"
              onClick={refreshSession}
            >
              Refresh form session
            </button>
          )}
        </div>
      )}

      <div className={modal ? "intake-submit intake-submit-sticky" : "intake-submit"}>
        <button type="submit" disabled={pending || !token}>
          {pending ? "Submitting…" : "Submit Request"}
        </button>
      </div>
    </form>
  );
}
