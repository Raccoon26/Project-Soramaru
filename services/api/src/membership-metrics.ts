import type { Database,QueryMeta,SqlValue,Statement } from './platform.ts';

export function observeDatabase(db:Database,observe:(meta:QueryMeta)=>void): Database {
  function prepare(native:Statement): Statement {
    return {
      bind:(...values:SqlValue[])=>prepare(native.bind(...values)),
      async all<T>() {
        const result=await native.all<T>();
        observe(result.meta);
        return result;
      },
      async first<T>() {
        const result=await native.all<T>();
        observe(result.meta);
        return result.results[0]??null;
      },
      async run() {
        const result=await native.run();
        observe(result.meta);
        return result;
      },
    };
  }
  const originals=new WeakMap<Statement,Statement>();
  function tracked(native:Statement): Statement {
    const wrapped=prepare(native);
    const result:Statement={...wrapped,bind:(...values)=>tracked(native.bind(...values))};
    originals.set(result,native);
    return result;
  }
  return {
    prepare:sql=>tracked(db.prepare(sql)),
    async batch<T>(queries:Statement[]) {
      const result=await db.batch<T>(queries.map(statement=>originals.get(statement)??statement));
      for (const query of result) observe(query.meta);
      return result;
    },
  };
}
