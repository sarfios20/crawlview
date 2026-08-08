const SVG_NS = "http://www.w3.org/2000/svg"
const NODE_EVENT = "site_graph:node"
const RESET_EVENT = "site_graph:reset"
const BROKEN_OUTCOMES = new Set([
  "not_found",
  "client_error",
  "server_error",
  "timeout",
  "unreachable",
])

const RING_SPACING = 52
const COMFORTABLE_NODE_COUNT = 160

// How long existing nodes take to slide to their new places. The layout is recomputed
// on every arrival, so without this every node on screen teleports each time a page
// lands, which is the part that actually looked rough.
const TWEEN_MS = 320

// The ramp has six steps and a crawl may go deeper, so anything past the last step
// wears it. Depth beyond five is rare and the exact figure still shows in the table.
const RAMP_STEPS = 6
const depthColor = depth => `var(--depth-${Math.min(depth, RAMP_STEPS - 1)})`

const reducedMotion = () => window.matchMedia("(prefers-reduced-motion: reduce)").matches
const easeOut = t => 1 - Math.pow(1 - t, 3)

const el = (tag, className, text) => {
  const node = document.createElement(tag)
  if (className) node.className = className
  if (text !== undefined) node.textContent = text
  return node
}

const svgEl = (tag, attributes = {}) => {
  const node = document.createElementNS(SVG_NS, tag)
  for (const [name, value] of Object.entries(attributes)) node.setAttribute(name, value)
  return node
}

const SiteGraph = {
  mounted() {
    this.nodes = new Map()
    this.nodeEls = new Map()
    this.edgeEls = new Map()
    this.from = new Map()
    this.to = new Map()
    this.swept = false
    this.ringDepth = -1
    this.hovered = null
    this.pinned = null
    this.tween = null

    this.svg = svgEl("svg", {
      role: "img",
      "aria-label": "Radial plot of crawled pages by link depth",
      "aria-describedby": "site-graph-description",
      class: "plot__svg",
    })

    this.ringLayer = svgEl("g", {"aria-hidden": "true"})
    this.edgeLayer = svgEl("g", {"aria-hidden": "true", class: "plot__edges"})
    this.nodeLayer = svgEl("g")
    this.svg.append(this.ringLayer, this.edgeLayer, this.nodeLayer)

    // The label is HTML rather than SVG text so it can wrap, use the page's own type
    // and hold a real link. It is anchored to the node, not the cursor: a tooltip that
    // chases the pointer shakes and is hard to read.
    this.tip = el("div", "plot__tip")
    this.tip.hidden = true

    // The key is built here rather than server-side because this hook already holds
    // every node: the per-depth tally is a property of the picture, so computing it
    // here keeps the server from mirroring crawl state it does not own.
    this.key = el("div", "plot__key")

    this.warning = el("p", "plot__warning")
    this.warning.setAttribute("role", "status")
    this.warning.hidden = true

    this.canvas = el("div", "plot__canvas-inner")
    this.canvas.append(this.svg, this.tip)

    const figure = el("div", "plot__figure")
    figure.append(this.canvas, this.key)
    this.el.replaceChildren(figure, this.warning)

    this.handleEvent(NODE_EVENT, node => {
      this.nodes.set(node.url, node)
      this.render()
    })

    this.handleEvent(RESET_EVENT, () => {
      this.nodes.clear()
      this.nodeEls.clear()
      this.edgeEls.clear()
      this.from.clear()
      this.to.clear()
      this.nodeLayer.replaceChildren()
      this.edgeLayer.replaceChildren()
      this.swept = false
      this.ringDepth = -1
      this.select(null, {pinned: false})
      this.pinned = null
      this.render()
    })

    // Clicking the empty canvas clears a pinned selection, which is what everyone
    // tries first. Escape does the same for the keyboard.
    this.onCanvasClick = event => {
      if (!event.target.closest("[data-node]")) this.pin(null)
    }
    this.onKeyDown = event => {
      if (event.key === "Escape") this.pin(null)
    }
    this.canvas.addEventListener("click", this.onCanvasClick)
    window.addEventListener("keydown", this.onKeyDown)

    // The table is rendered and streamed by the server, so the hook reaches it by
    // delegation rather than owning it. Hovering a row lights its node and vice versa:
    // the plot and the table are two views of one set of pages, and this is what makes
    // that legible instead of merely true.
    this.rows = document.getElementById("crawl-pages")

    if (this.rows) {
      this.onRowOver = event => {
        const row = event.target.closest("[data-url]")
        if (row) this.select(row.dataset.url, {pinned: false, fromRow: true})
      }
      this.onRowOut = event => {
        if (!event.relatedTarget || !this.rows.contains(event.relatedTarget)) {
          this.select(null, {pinned: false})
        }
      }
      this.rows.addEventListener("mouseover", this.onRowOver)
      this.rows.addEventListener("mouseout", this.onRowOut)
    }

    this.render()
  },

  destroyed() {
    this.canvas.removeEventListener("click", this.onCanvasClick)
    window.removeEventListener("keydown", this.onKeyDown)

    if (this.rows) {
      this.rows.removeEventListener("mouseover", this.onRowOver)
      this.rows.removeEventListener("mouseout", this.onRowOut)
    }

    if (this.tween) cancelAnimationFrame(this.tween)
  },

  render() {
    const nodes = [...this.nodes.values()]
    const {children, roots} = this.buildTree(nodes)
    const target = this.layout({children, roots})
    const maximumDepth = nodes.reduce((maximum, node) => Math.max(maximum, node.depth), 0)

    this.children = children
    this.radii = this.markRadii(nodes)
    this.sizeFrame(maximumDepth)
    this.drawRings(maximumDepth)
    this.syncElements(nodes, target)
    this.drawKey(nodes, maximumDepth)
    this.edgeLayer.style.strokeOpacity = nodes.length > 80 ? "0.4" : "1"

    // Nodes that have never been placed start where they will end up, so a new node
    // fades in rather than flying across the plot from the centre.
    for (const [url, point] of target) {
      if (!this.from.has(url)) this.from.set(url, point)
    }

    this.to = target
    this.startTween()

    if (nodes.length > COMFORTABLE_NODE_COUNT) {
      this.warning.textContent = `${nodes.length} pages plotted. The picture is getting dense; the table below stays readable.`
      this.warning.hidden = false
    } else {
      this.warning.textContent = ""
      this.warning.hidden = true
    }
  },

  // A mark sizes itself to how crowded its own ring is. One page linking to five
  // hundred others is normal (an archive index), and at a fixed five pixels those
  // children merge into a smear; shrunk to fit the arc they read as a fine dotted
  // ring, which is both prettier and more truthful about how many there are.
  markRadii(nodes) {
    const perDepth = new Map()
    for (const node of nodes) perDepth.set(node.depth, (perDepth.get(node.depth) || 0) + 1)

    const radii = new Map()

    for (const [depth, count] of perDepth) {
      if (depth === 0) {
        radii.set(depth, 8)
        continue
      }

      const circumference = 2 * Math.PI * depth * RING_SPACING
      const arcPerNode = circumference / count
      radii.set(depth, Math.max(1.6, Math.min(5, (arcPerNode * 0.8) / 2)))
    }

    return radii
  },

  sizeFrame(maximumDepth) {
    // The frame follows the tree instead of the tree sitting inside a fixed frame, so
    // a shallow site is not a small blob in a large empty box.
    const viewRadius = Math.max(maximumDepth, 1) * RING_SPACING + 26
    this.svg.setAttribute(
      "viewBox",
      `${-viewRadius} ${-viewRadius} ${viewRadius * 2} ${viewRadius * 2}`
    )
  },

  buildTree(nodes) {
    const byUrl = this.nodes
    const children = new Map(nodes.map(node => [node.url, []]))
    const roots = []

    for (const node of nodes) {
      const parent = node.referrer && byUrl.get(node.referrer)

      // A referrer can arrive after its child. Until then that child is a top-level
      // subtree with an edge to the centre; rebuilding this index on every event
      // attaches it to its real parent as soon as that parent exists, so a node is
      // never dropped and the picture never breaks.
      if (parent && parent.url !== node.url) {
        children.get(parent.url).push(node)
      } else {
        roots.push(node)
      }
    }

    for (const siblings of children.values()) {
      siblings.sort((left, right) => left.url.localeCompare(right.url))
    }
    roots.sort((left, right) => left.url.localeCompare(right.url))

    return {children, roots}
  },

  layout({children, roots}) {
    // Angular share follows the SQUARE ROOT of a subtree's size, not its size. One
    // archive page linking to five hundred posts would otherwise take 95% of the
    // circle and squeeze every other top-level section into an invisible sliver. The
    // root of the count keeps the biggest branch visibly the biggest while leaving the
    // structural siblings readable, which is what the picture is for: those fifteen
    // front-page sections say more about the shape of a site than the individual posts
    // hanging off one of them.
    const sizes = new Map()
    const subtreeSize = node => {
      const childNodes = children.get(node.url)
      const size = Math.max(1, childNodes.reduce((sum, child) => sum + subtreeSize(child), 0))
      sizes.set(node.url, size)
      return size
    }
    roots.forEach(subtreeSize)

    const weights = new Map()
    for (const [url, size] of sizes) weights.set(url, Math.sqrt(size))

    const positions = new Map()

    // Radius is depth: each click from the front page adds one ring. Angle is position
    // within the parent's slice, divided in proportion to subtree size, so siblings fan
    // out and a branch stays visually together.
    const positionSubtree = (node, sliceStart, sliceEnd) => {
      const angle = (sliceStart + sliceEnd) / 2
      const radius = node.depth * RING_SPACING
      positions.set(node.url, {x: Math.cos(angle) * radius, y: Math.sin(angle) * radius})

      const childNodes = children.get(node.url)
      const totalWeight = childNodes.reduce((sum, child) => sum + weights.get(child.url), 0)
      let cursor = sliceStart

      for (const child of childNodes) {
        const width = (sliceEnd - sliceStart) * (weights.get(child.url) / totalWeight)
        positionSubtree(child, cursor, cursor + width)
        cursor += width
      }
    }

    const totalRootWeight = roots.reduce((sum, root) => sum + weights.get(root.url), 0)
    let rootCursor = -Math.PI / 2

    for (const root of roots) {
      const width = Math.PI * 2 * (weights.get(root.url) / totalRootWeight)
      positionSubtree(root, rootCursor, rootCursor + width)
      rootCursor += width
    }

    return positions
  },

  drawRings(maximumDepth) {
    if (maximumDepth === this.ringDepth) return

    const sweep = !this.swept && maximumDepth > 0 && !reducedMotion()
    if (maximumDepth > 0) this.swept = true
    this.ringDepth = maximumDepth

    this.ringLayer.setAttribute("class", sweep ? "plot__rings--sweep" : "")
    this.ringLayer.replaceChildren()

    for (let depth = 1; depth <= maximumDepth; depth += 1) {
      this.ringLayer.append(
        svgEl("circle", {
          r: depth * RING_SPACING,
          fill: "none",
          stroke: "var(--plot-ring)",
          "stroke-width": "1",
          "stroke-dasharray": "2 6",
        })
      )

      // Range rings carry their own number, the way a contour carries its elevation,
      // so the scale is learned from the picture rather than from prose.
      // The label sits just OUTSIDE its ring, in the gap between rings, because nodes
      // sit exactly on the ring and would otherwise cover it. The surface-coloured
      // outline keeps it legible wherever a node still lands close.
      const label = svgEl("text", {
        x: 0,
        y: -depth * RING_SPACING - 7,
        "text-anchor": "middle",
        fill: "var(--color-base-content)",
        "fill-opacity": "0.45",
        "font-size": "10",
        "font-family": "var(--font-data)",
        stroke: "var(--plot-surface)",
        "stroke-width": "3",
        "stroke-opacity": "0.9",
        "paint-order": "stroke fill",
      })
      label.textContent = depth
      this.ringLayer.append(label)
    }
  },

  // Elements persist across renders and are keyed by URL, which is what allows a
  // position change to be animated instead of replaced.
  syncElements(nodes, target) {
    for (const node of nodes) {
      if (!this.nodeEls.has(node.url)) this.createNode(node)
      this.paintNodeAppearance(node)

      const hasParent = node.depth > 0
      if (hasParent && !this.edgeEls.has(node.url)) {
        const edge = svgEl("line", {"data-edge": node.url})
        this.edgeEls.set(node.url, edge)
        this.edgeLayer.append(edge)
      }
    }

    for (const [url, entry] of this.nodeEls) {
      if (!target.has(url)) {
        entry.group.remove()
        this.nodeEls.delete(url)
        this.from.delete(url)
      }
    }

    for (const [url, edge] of this.edgeEls) {
      if (!target.has(url)) {
        edge.remove()
        this.edgeEls.delete(url)
      }
    }
  },

  createNode(node) {
    const group = svgEl("g", {tabindex: "0", "data-node": node.url})
    const visual = svgEl("g")
    group.append(visual)

    group.addEventListener("pointerenter", () => this.select(node.url, {pinned: false}))
    group.addEventListener("pointerleave", () => this.select(null, {pinned: false}))
    group.addEventListener("focus", () => this.select(node.url, {pinned: false}))
    group.addEventListener("blur", () => this.select(null, {pinned: false}))

    // Click selects; it deliberately does not navigate. These are five-pixel targets
    // and a misclick that yanks you to another tab is a hostile way to lose your place.
    // Opening the page is an explicit link in the label instead. It also means touch,
    // which has no hover, gets everything hovering gives.
    group.addEventListener("click", event => {
      event.stopPropagation()
      this.pin(this.pinned === node.url ? null : node.url)
    })
    group.addEventListener("keydown", event => {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault()
        this.pin(this.pinned === node.url ? null : node.url)
      }
    })

    this.nodeEls.set(node.url, {group, visual})
    this.nodeLayer.append(group)

    if (!reducedMotion()) {
      visual.animate(
        [
          {opacity: 0, transform: "scale(0.4)"},
          {opacity: 1, transform: "scale(1)"},
        ],
        {duration: 260, easing: "cubic-bezier(0.2, 0.8, 0.2, 1)"}
      )
    }
  },

  paintNodeAppearance(node) {
    const {group, visual} = this.nodeEls.get(node.url)
    const broken = BROKEN_OUTCOMES.has(node.outcome)

    group.setAttribute(
      "aria-label",
      `${node.url}, depth ${node.depth}, ${node.outcome_label}`
    )
    group.dataset.broken = String(broken)
    visual.replaceChildren()

    if (broken) {
      // Broken pages carry an outer ring as well as the reserved colour, so they stay
      // identifiable in greyscale, in forced colours and to a colour-blind reader.
      visual.append(
        svgEl("circle", {r: "9.5", fill: "none", stroke: "var(--plot-surface)", "stroke-width": "3"}),
        svgEl("circle", {r: "9.5", fill: "none", stroke: "var(--broken)", "stroke-width": "1.75"}),
        svgEl("circle", {r: "5", fill: "var(--broken)"})
      )
    } else {
      const radius = this.radii.get(node.depth) ?? 5
      visual.append(
        svgEl("circle", {
          r: radius,
          fill: depthColor(node.depth),
          stroke: "var(--plot-surface)",
          "stroke-width": radius < 3 ? "0.6" : "1.5",
        })
      )
    }
  },

  startTween() {
    if (this.tween) cancelAnimationFrame(this.tween)

    if (reducedMotion()) {
      this.from = new Map(this.to)
      this.paint()
      return
    }

    const start = performance.now()
    const from = new Map(this.from)

    const step = now => {
      const progress = Math.min(1, (now - start) / TWEEN_MS)
      const eased = easeOut(progress)
      const frame = new Map()

      for (const [url, to] of this.to) {
        const previous = from.get(url) || to
        frame.set(url, {
          x: previous.x + (to.x - previous.x) * eased,
          y: previous.y + (to.y - previous.y) * eased,
        })
      }

      this.from = frame
      this.paint()

      if (progress < 1) {
        this.tween = requestAnimationFrame(step)
      } else {
        this.tween = null
      }
    }

    this.tween = requestAnimationFrame(step)
  },

  paint() {
    for (const [url, entry] of this.nodeEls) {
      const point = this.from.get(url)
      if (point) entry.group.setAttribute("transform", `translate(${point.x} ${point.y})`)
    }

    for (const [url, edge] of this.edgeEls) {
      const node = this.nodes.get(url)
      const point = this.from.get(url)
      if (!node || !point) continue

      const parent = node.referrer && this.from.get(node.referrer)
      edge.setAttribute("x1", parent ? parent.x : 0)
      edge.setAttribute("y1", parent ? parent.y : 0)
      edge.setAttribute("x2", point.x)
      edge.setAttribute("y2", point.y)
    }

    if (this.focusUrl()) this.positionTip(this.focusUrl())
  },

  focusUrl() {
    return this.hovered || this.pinned
  },

  pin(url) {
    this.pinned = url
    this.select(url, {pinned: true})

    // Selecting in the plot scrolls the record to the matching row. The table is the
    // accessible, readable account of a page, so pointing at it beats rebuilding a
    // detail panel in JavaScript.
    if (url && this.rows) {
      const row = this.rows.querySelector(`[data-url="${CSS.escape(url)}"]`)
      if (row) row.scrollIntoView({block: "nearest", behavior: reducedMotion() ? "auto" : "smooth"})
    }
  },

  select(url, {pinned = false, fromRow = false} = {}) {
    this.hovered = pinned ? null : url
    const focus = this.focusUrl()

    this.applyHighlight(focus)
    this.markRows(focus)

    if (focus) {
      this.showTip(focus, {navigable: this.pinned === focus})
      if (fromRow) this.nodeEls.get(focus)?.group?.classList?.add("is-focus")
    } else {
      this.tip.hidden = true
    }
  },

  // The chain walked here is the route the crawl took to find the page, which is the
  // SHORTEST route from the front page: the frontier is breadth-first, so the first
  // discovery of any URL is always via a minimum-length path. It is not the only route,
  // because a page can be linked from many places and only the first discoverer is
  // recorded as its referrer, so the label says "shortest route" and never "linked from".
  ancestry(url) {
    const chain = []
    const seen = new Set()
    let current = url

    while (current && this.nodes.has(current) && !seen.has(current)) {
      seen.add(current)
      chain.push(current)
      current = this.nodes.get(current).referrer
    }

    return chain
  },

  applyHighlight(focus) {
    const chain = focus ? new Set(this.ancestry(focus)) : null
    this.canvas.classList.toggle("is-focused", Boolean(focus))

    for (const [url, entry] of this.nodeEls) {
      entry.group.classList.toggle("is-chain", Boolean(chain && chain.has(url)))
      entry.group.classList.toggle("is-focus", url === focus)
    }

    for (const [url, edge] of this.edgeEls) {
      const node = this.nodes.get(url)
      const onChain = Boolean(chain && chain.has(url) && node && chain.has(node.referrer))
      edge.classList.toggle("is-chain", onChain)
    }
  },

  markRows(focus) {
    if (!this.rows) return

    for (const row of this.rows.querySelectorAll("[data-url].is-linked")) {
      row.classList.remove("is-linked")
    }

    if (!focus) return
    const row = this.rows.querySelector(`[data-url="${CSS.escape(focus)}"]`)
    if (row) row.classList.add("is-linked")
  },

  showTip(url, {navigable}) {
    const node = this.nodes.get(url)
    if (!node) return

    const clicks = Math.max(0, this.ancestry(url).length - 1)
    const parts = []

    parts.push(el("p", "tip__path", this.shortPath(url)))
    if (node.title) parts.push(el("p", "tip__title", node.title))

    const facts = el("p", "tip__facts")
    facts.append(
      el("span", "tip__status", `${node.status ?? "no response"} ${node.outcome_label}`),
      el(
        "span",
        "tip__depth",
        clicks === 0 ? "the front page" : `${clicks} ${clicks === 1 ? "click" : "clicks"} from the front page`
      )
    )
    parts.push(facts)

    if (navigable) {
      const open = el("a", "tip__open", "Open page ↗")
      open.href = url
      open.target = "_blank"
      open.rel = "noreferrer"
      parts.push(open)
    }

    this.tip.replaceChildren(...parts)
    this.tip.dataset.broken = String(BROKEN_OUTCOMES.has(node.outcome))
    this.tip.dataset.pinned = String(navigable)
    this.tip.hidden = false
    this.positionTip(url)
  },

  positionTip(url) {
    const point = this.from.get(url)
    if (!point || this.tip.hidden) return

    // The plot's user units map to the canvas through the viewBox, so the label is
    // placed as a percentage and stays anchored while the frame grows.
    const radius = Math.max(this.ringDepth, 1) * RING_SPACING + 26
    this.tip.style.left = `${((point.x + radius) / (radius * 2)) * 100}%`
    this.tip.style.top = `${((point.y + radius) / (radius * 2)) * 100}%`

    // A label always drawn above its node would be clipped for anything in the top
    // half of the plot, so it flips below instead of hanging off the frame.
    this.tip.dataset.below = String(point.y < 0)
  },

  shortPath(url) {
    try {
      const parsed = new URL(url)
      return (parsed.pathname || "/") + (parsed.search || "")
    } catch {
      return url
    }
  },

  // The key is legend, tally and distribution in one column: it names what the colours
  // mean, counts what has been found, and shows where the site's weight sits.
  drawKey(nodes, maximumDepth) {
    const counts = new Array(maximumDepth + 1).fill(0)
    let brokenCount = 0

    for (const node of nodes) {
      counts[node.depth] = (counts[node.depth] || 0) + 1
      if (BROKEN_OUTCOMES.has(node.outcome)) brokenCount += 1
    }

    const busiest = Math.max(1, ...counts)
    const rows = el("div", "key__rows")

    counts.forEach((count, depth) => {
      const row = el("div", "key__row")
      row.style.color = depthColor(depth)

      const dot = el("span", "key__dot")
      dot.style.background = depthColor(depth)

      const bar = el("span", "key__bar")
      bar.style.width = `${(count / busiest) * 100}%`

      row.append(dot, el("span", "key__depth", `${depth}`), bar, el("span", "key__count", `${count}`))
      rows.append(row)
    })

    const depths = el("div")
    depths.append(el("p", "key__heading", "Clicks from front page"), rows)

    const broken = el("div", "key__broken")
    broken.append(
      el("span", "key__broken-mark"),
      el("span", "key__broken-label", "Broken"),
      el("span", "key__broken-count", `${brokenCount}`)
    )

    this.key.replaceChildren(depths, broken)
  },
}

export default SiteGraph
