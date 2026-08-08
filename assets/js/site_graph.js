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
const VIEW_RADIUS = 300
const COMFORTABLE_NODE_COUNT = 160

const SiteGraph = {
  mounted() {
    this.nodes = new Map()

    this.svg = document.createElementNS(SVG_NS, "svg")
    this.svg.setAttribute("viewBox", `${-VIEW_RADIUS} ${-VIEW_RADIUS} ${VIEW_RADIUS * 2} ${VIEW_RADIUS * 2}`)
    this.svg.setAttribute("role", "img")
    this.svg.setAttribute("aria-label", "Radial tree of crawled pages by link depth")
    this.svg.setAttribute("aria-describedby", "site-graph-description")
    this.svg.setAttribute("class", "block aspect-square w-full")

    this.warning = document.createElement("p")
    this.warning.setAttribute("role", "status")
    this.warning.setAttribute("class", "alert alert-warning mt-3 hidden text-sm")

    this.el.replaceChildren(this.svg, this.warning)

    this.handleEvent(NODE_EVENT, node => {
      const isNew = !this.nodes.has(node.url)
      this.nodes.set(node.url, node)
      this.renderGraph(isNew ? node.url : null)
    })

    this.handleEvent(RESET_EVENT, () => {
      this.nodes.clear()
      this.renderGraph(null)
    })

    this.renderGraph(null)
  },

  renderGraph(newUrl) {
    const nodes = [...this.nodes.values()]
    const byUrl = this.nodes
    const children = new Map(nodes.map(node => [node.url, []]))
    const roots = []

    for (const node of nodes) {
      const parent = node.referrer && byUrl.get(node.referrer)

      // A referrer can arrive after its child. Until then that child is a
      // top-level subtree with an edge to the centre; rebuilding this index on
      // every event attaches it to its real parent as soon as that parent exists.
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

    const weights = new Map()
    const subtreeWeight = node => {
      const childNodes = children.get(node.url)
      const weight = Math.max(1, childNodes.reduce((sum, child) => sum + subtreeWeight(child), 0))
      weights.set(node.url, weight)
      return weight
    }
    roots.forEach(subtreeWeight)

    const positions = new Map()

    // Coordinates are SVG user units: each depth adds one 52-unit ring. A
    // recursive pass divides a parent's angular slice in proportion to its
    // children's subtree sizes, keeping siblings fanned out and branches
    // together. Recomputing all angles is clearer than incremental geometry and
    // is comfortably fast for the crawler's 200-page cap.
    const positionSubtree = (node, sliceStart, sliceEnd) => {
      const angle = (sliceStart + sliceEnd) / 2
      const radius = node.depth * RING_SPACING
      positions.set(node.url, {
        x: Math.cos(angle) * radius,
        y: Math.sin(angle) * radius,
      })

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

    const ringLayer = document.createElementNS(SVG_NS, "g")
    ringLayer.setAttribute("aria-hidden", "true")
    ringLayer.setAttribute("fill", "none")
    ringLayer.setAttribute("stroke", "var(--color-base-content)")
    ringLayer.setAttribute("stroke-opacity", "0.12")
    ringLayer.setAttribute("stroke-width", "1")
    ringLayer.setAttribute("stroke-dasharray", "3 5")

    const maximumDepth = nodes.reduce((maximum, node) => Math.max(maximum, node.depth), 0)

    // The frame follows the tree instead of the tree sitting inside a fixed
    // frame. A constant viewBox sized for the deepest crawl we allow would leave
    // a shallow site as a small blob in the middle of a large empty box, so the
    // radius is recomputed from the depth actually reached, plus room for the
    // outermost node's own radius and its focus ring.
    const viewRadius = Math.max(maximumDepth, 1) * RING_SPACING + 24
    this.svg.setAttribute(
      "viewBox",
      `${-viewRadius} ${-viewRadius} ${viewRadius * 2} ${viewRadius * 2}`
    )

    for (let depth = 1; depth <= maximumDepth; depth += 1) {
      const ring = document.createElementNS(SVG_NS, "circle")
      ring.setAttribute("r", depth * RING_SPACING)
      ringLayer.append(ring)
    }

    const edgeLayer = document.createElementNS(SVG_NS, "g")
    edgeLayer.setAttribute("aria-hidden", "true")
    edgeLayer.setAttribute("fill", "none")
    edgeLayer.setAttribute("stroke", "var(--color-base-content)")
    edgeLayer.setAttribute("stroke-opacity", "0.24")
    edgeLayer.setAttribute("stroke-width", "1.5")

    for (const node of nodes) {
      if (node.depth === 0) continue

      const point = positions.get(node.url)
      const parentPoint = node.referrer && positions.get(node.referrer)
      const edge = document.createElementNS(SVG_NS, "line")
      edge.setAttribute("x1", parentPoint ? parentPoint.x : 0)
      edge.setAttribute("y1", parentPoint ? parentPoint.y : 0)
      edge.setAttribute("x2", point.x)
      edge.setAttribute("y2", point.y)
      edgeLayer.append(edge)
    }

    const nodeLayer = document.createElementNS(SVG_NS, "g")

    for (const node of nodes) {
      const point = positions.get(node.url)
      const group = document.createElementNS(SVG_NS, "g")
      group.setAttribute("transform", `translate(${point.x} ${point.y})`)
      group.setAttribute("tabindex", "0")
      group.setAttribute("aria-label", `${node.url}, depth ${node.depth}, outcome ${node.outcome}`)

      const title = document.createElementNS(SVG_NS, "title")
      title.textContent = node.url
      group.append(title)

      const visual = document.createElementNS(SVG_NS, "g")
      const broken = BROKEN_OUTCOMES.has(node.outcome)

      if (broken) {
        const ring = document.createElementNS(SVG_NS, "circle")
        ring.setAttribute("r", "10")
        ring.setAttribute("fill", "none")
        ring.setAttribute("stroke", "var(--color-error)")
        ring.setAttribute("stroke-width", "2.5")
        visual.append(ring)

        const circle = document.createElementNS(SVG_NS, "circle")
        circle.setAttribute("r", "6.5")
        circle.setAttribute("fill", "var(--color-error)")
        circle.setAttribute("stroke", "var(--color-error-content)")
        circle.setAttribute("stroke-width", "1")
        visual.append(circle)
      } else {
        const circle = document.createElementNS(SVG_NS, "circle")
        circle.setAttribute("r", node.depth === 0 ? "7" : "5")
        circle.setAttribute("fill", "var(--color-primary)")
        circle.setAttribute("stroke", "var(--color-primary-content)")
        circle.setAttribute("stroke-width", "1")
        visual.append(circle)
      }

      group.append(visual)
      nodeLayer.append(group)

      if (node.url === newUrl && !window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
        visual.animate(
          [
            {opacity: 0, transform: "scale(0.35)"},
            {opacity: 1, transform: "scale(1)"},
          ],
          {duration: 260, easing: "ease-out"},
        )
      }
    }

    this.svg.replaceChildren(ringLayer, edgeLayer, nodeLayer)

    if (nodes.length > COMFORTABLE_NODE_COUNT) {
      this.warning.textContent = `This graph contains ${nodes.length} pages and is becoming dense. The table remains the readable record of every page.`
      this.warning.classList.remove("hidden")
    } else {
      this.warning.textContent = ""
      this.warning.classList.add("hidden")
    }
  },
}

export default SiteGraph
